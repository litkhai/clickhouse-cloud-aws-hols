// cachebench: closed-loop load generator for ClickHouse Cloud, Valkey and DynamoDB.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
)

func fail(format string, a ...any) int {
	fmt.Fprintf(os.Stderr, "cachebench: "+format+"\n", a...)
	return 2
}

// parseFlags returns (exit code, true) when the caller should return (error or --help).
func parseFlags(fs *flag.FlagSet, args []string) (int, bool) {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0, true
		}
		return 2, true
	}
	return 0, false
}

func main() {
	if len(os.Args) < 2 {
		os.Exit(fail("usage: cachebench floor|load-kv|run [flags]  (--help on each)"))
	}
	var code int
	switch os.Args[1] {
	case "floor":
		code = cmdFloor(os.Args[2:])
	case "load-kv":
		code = cmdLoadKV(os.Args[2:])
	case "run":
		code = cmdRun(os.Args[2:])
	default:
		code = fail("unknown subcommand %q (floor|load-kv|run)", os.Args[1])
	}
	os.Exit(code)
}
