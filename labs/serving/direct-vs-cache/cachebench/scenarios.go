package main

import (
	"crypto/sha1"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"math/rand/v2"
	"slices"
	"strings"
)

//go:embed queries/s3_tiles.json
var tilesJSON []byte

type tile struct {
	ID  string `json:"id"`
	Raw string `json:"raw"`
	Agg string `json:"agg"`
}

func loadTiles() ([]tile, error) {
	var t []tile
	if err := json.Unmarshal(tilesJSON, &t); err != nil {
		return nil, err
	}
	if len(t) == 0 {
		return nil, fmt.Errorf("s3_tiles.json is empty")
	}
	return t, nil
}

// request is one drawn work item. raw is the "ch" query, agg the "ch-agg" query.
type request struct {
	key      string
	raw, agg string
	id       uint64 // s2 user id (kv arms), s1 query index k
}

var armsByScenario = map[string][]string{
	"s1": {"ch", "ch-qc", "vk-aside", "ddb-aside"},
	"s2": {"ch", "ch-agg", "vk-kv", "ddb-kv", "vk-aside", "ddb-aside"},
	"s3": {"ch", "ch-qc", "ch-agg", "vk-aside", "ddb-aside"},
}

func validArm(scn, arm string) bool {
	return slices.Contains(armsByScenario[scn], arm)
}

func isAside(arm string) bool { return strings.HasSuffix(arm, "-aside") }
func isKV(arm string) bool    { return strings.HasSuffix(arm, "-kv") }

// useAgg tells whether the ClickHouse side of this arm runs the "agg" query.
func useAgg(scn, arm string) bool {
	return arm == "ch-agg" || (scn == "s2" && isAside(arm))
}

func seedFor(runID string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(runID))
	return h.Sum64()
}

func newRNG(seed uint64, worker int) *rand.Rand {
	return rand.New(rand.NewPCG(seed, uint64(worker)+1))
}

// zipfDraw returns a Zipf(s) generator over [0, n). Needs s > 1 and n >= 2.
func zipfDraw(r *rand.Rand, s float64, n uint64) func() uint64 {
	z := rand.NewZipf(r, s, 1, n-1)
	return z.Uint64
}

// ---- s1: ad-hoc aggregation ----

var countries = []string{"KR", "US", "JP", "CN", "TW", "SG", "VN", "TH", "ID", "MY", "PH", "IN", "AU", "GB", "DE", "FR", "CA", "BR", "MX", "ES"}
var devices = []string{"mobile", "desktop", "tablet"}
var eventTypes = []string{"impression", "click", "view", "add_to_cart", "purchase"}
var s1Dims = []string{"campaign_id", "country", "device", "event_type", "toStartOfHour(ts)"}
var s1Lens = []int64{3600, 86400, 7 * 86400, 30 * 86400}

// mix64 is splitmix64's finalizer; it decorrelates PRNG streams seeded with consecutive k.
func mix64(x uint64) uint64 {
	x += 0x9e3779b97f4a7c15
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ^ (x >> 27)) * 0x94d049bb133111eb
	return x ^ (x >> 31)
}

// s1SQL maps query index k to a SQL text, deterministically (PRNG seeded with k only).
func s1SQL(base int64, k uint64) string {
	r := rand.New(rand.NewPCG(mix64(k), mix64(k+0x9e3779b97f4a7c15)))
	dim := s1Dims[r.IntN(len(s1Dims))]
	var conds []string
	if r.Float64() >= 0.5 {
		conds = append(conds, "country = '"+countries[r.IntN(len(countries))]+"'")
	}
	if r.Float64() >= 0.5 {
		conds = append(conds, "device = '"+devices[r.IntN(len(devices))]+"'")
	}
	if r.Float64() >= 0.5 {
		conds = append(conds, "event_type = '"+eventTypes[r.IntN(len(eventTypes))]+"'")
	}
	start := base + int64(r.IntN(720))*3600
	end := min(start+s1Lens[r.IntN(len(s1Lens))], base+30*86400)
	var sb strings.Builder
	fmt.Fprintf(&sb, "SELECT %s AS k, count() AS c, sum(revenue) AS r, uniq(user_id) AS u FROM cachelab.events WHERE ts >= toDateTime(%d) AND ts < toDateTime(%d)", dim, start, end)
	for _, c := range conds {
		sb.WriteString(" AND " + c)
	}
	sb.WriteString(" GROUP BY k ORDER BY c DESC LIMIT 100")
	return sb.String()
}

func s1Key(sql string) string {
	h := sha1.Sum([]byte(sql))
	return "s1:" + hex.EncodeToString(h[:])[:16]
}

// ---- drawers (one per worker) ----

type scnCfg struct {
	scn   string
	space int
	users int
	dist  string
	zipf  float64
	base  int64
	tiles []tile
}

func (c *scnCfg) drawer(r *rand.Rand) func() request {
	switch c.scn {
	case "s1":
		z := zipfDraw(r, c.zipf, uint64(c.space))
		return func() request {
			k := z()
			sql := s1SQL(c.base, k)
			return request{key: s1Key(sql), raw: sql, id: k}
		}
	case "s2":
		var next func() uint64
		if c.dist == "uniform" {
			next = func() uint64 { return r.Uint64N(uint64(c.users)) }
		} else {
			next = zipfDraw(r, c.zipf, uint64(c.users))
		}
		return func() request {
			id := next()
			return request{
				key: fmt.Sprintf("s2:%d", id), id: id,
				raw: fmt.Sprintf("SELECT count() AS events, sum(revenue) AS revenue, toUnixTimestamp(max(ts)) AS last_ts FROM cachelab.events WHERE user_id = %d", id),
				agg: fmt.Sprintf("SELECT sum(events) AS events, sum(revenue) AS revenue, toUnixTimestamp(max(last_ts)) AS last_ts FROM cachelab.user_stats WHERE user_id = %d", id),
			}
		}
	default: // s3
		z := zipfDraw(r, c.zipf, uint64(len(c.tiles)))
		return func() request {
			t := c.tiles[z()]
			return request{key: "s3:" + t.ID, raw: t.Raw, agg: t.Agg}
		}
	}
}

func ingestSQL(rows int) string {
	return fmt.Sprintf(`INSERT INTO cachelab.events SELECT now() AS ts, toUInt32(rand(1) %% 1000000), toUInt16(rand(2) %% 1000),
 ['KR','US','JP','CN','TW','SG','VN','TH','ID','MY','PH','IN','AU','GB','DE','FR','CA','BR','MX','ES'][1 + rand(3) %% 20],
 ['mobile','desktop','tablet'][1 + rand(4) %% 3], ['impression','click','view','add_to_cart','purchase'][1 + rand(5) %% 5],
 (rand(6) %% 10000) / 100 FROM numbers(%d)`, rows)
}
