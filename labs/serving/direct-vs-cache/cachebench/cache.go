package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/redis/go-redis/v9"
)

const ddbMaxBody = 390 * 1024

var errTooLarge = errors.New("body larger than 390 KiB")

// Cache is the cache-aside side: Get reports (body, hit).
type Cache interface {
	Get(ctx context.Context, key string) ([]byte, bool, error)
	Put(ctx context.Context, key string, body []byte, ttl time.Duration) error
}

// KV is the point-lookup side: returns answer bytes and whether the key exists.
type KV interface {
	Lookup(ctx context.Context, id uint64) ([]byte, bool, error)
}

// ---- Valkey ----

type vk struct{ c *redis.Client }

func newVK(conc int) (*vk, error) {
	if err := needEnv("VK_ADDR"); err != nil {
		return nil, err
	}
	o := &redis.Options{
		Addr: os.Getenv("VK_ADDR"), Password: os.Getenv("VK_PASSWORD"),
		PoolSize: conc + 4, MinIdleConns: min(conc, 64),
		ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second,
	}
	if getenv("VK_TLS", "1") != "0" {
		o.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	return &vk{redis.NewClient(o)}, nil
}

func (v *vk) wrap(err error) error { return &classErr{"vk_err", err} }

func (v *vk) Get(ctx context.Context, key string) ([]byte, bool, error) {
	b, err := v.c.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, v.wrap(err)
	}
	return b, true, nil
}

func (v *vk) Put(ctx context.Context, key string, body []byte, ttl time.Duration) error {
	if err := v.c.Set(ctx, key, body, ttl).Err(); err != nil {
		return v.wrap(err)
	}
	return nil
}

func (v *vk) Lookup(ctx context.Context, id uint64) ([]byte, bool, error) {
	m, err := v.c.HGetAll(ctx, "user:"+strconv.FormatUint(id, 10)).Result()
	if err != nil {
		return nil, false, v.wrap(err)
	}
	if len(m) == 0 {
		return nil, false, nil
	}
	return []byte(m["events"] + "," + m["revenue"] + "," + m["last_ts"]), true, nil
}

// ---- DynamoDB ----

type ddb struct {
	c           *dynamodb.Client
	kvT, asideT string
}

func newDDB() (*ddb, error) {
	if err := needEnv("DDB_KV_TABLE", "DDB_ASIDE_TABLE"); err != nil {
		return nil, err
	}
	cfg, err := config.LoadDefaultConfig(context.Background(), config.WithRegion(getenv("AWS_REGION", "ap-northeast-2")))
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}
	return &ddb{c: dynamodb.NewFromConfig(cfg), kvT: os.Getenv("DDB_KV_TABLE"), asideT: os.Getenv("DDB_ASIDE_TABLE")}, nil
}

func (d *ddb) wrap(err error) error { return &classErr{"ddb_err", err} }

func (d *ddb) getItem(ctx context.Context, table, pk string) (map[string]types.AttributeValue, error) {
	out, err := d.c.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(table), ConsistentRead: aws.Bool(false),
		Key: map[string]types.AttributeValue{"pk": &types.AttributeValueMemberS{Value: pk}},
	})
	if err != nil {
		return nil, d.wrap(err)
	}
	return out.Item, nil
}

func (d *ddb) Get(ctx context.Context, key string) ([]byte, bool, error) {
	item, err := d.getItem(ctx, d.asideT, key)
	if err != nil || item == nil {
		return nil, false, err
	}
	exp, ok := item["exp"].(*types.AttributeValueMemberN)
	if !ok {
		return nil, false, nil
	}
	e, _ := strconv.ParseInt(exp.Value, 10, 64)
	if e <= time.Now().Unix() { // TTL deletion lags: check expiry on read
		return nil, false, nil
	}
	b, ok := item["body"].(*types.AttributeValueMemberB)
	if !ok {
		return nil, false, nil
	}
	return b.Value, true, nil
}

func (d *ddb) Put(ctx context.Context, key string, body []byte, ttl time.Duration) error {
	if len(body) > ddbMaxBody {
		return errTooLarge
	}
	_, err := d.c.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(d.asideT),
		Item: map[string]types.AttributeValue{
			"pk":   &types.AttributeValueMemberS{Value: key},
			"body": &types.AttributeValueMemberB{Value: body},
			"exp":  &types.AttributeValueMemberN{Value: strconv.FormatInt(time.Now().Add(ttl).Unix(), 10)},
		},
	})
	if err != nil {
		return d.wrap(err)
	}
	return nil
}

func (d *ddb) Lookup(ctx context.Context, id uint64) ([]byte, bool, error) {
	item, err := d.getItem(ctx, d.kvT, "u#"+strconv.FormatUint(id, 10))
	if err != nil {
		return nil, false, err
	}
	if item == nil {
		return nil, false, nil
	}
	var sb strings.Builder
	for _, k := range []string{"events", "revenue", "last_ts"} {
		if n, ok := item[k].(*types.AttributeValueMemberN); ok {
			sb.WriteString(n.Value + ",")
		}
	}
	return []byte(sb.String()), true, nil
}
