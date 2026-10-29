# Benchmarks and the mechanical check. `make bench` is the entry point: it builds, runs
# every layer and writes bench/report.md. docs/BENCHMARK.md explains the layers.
#
#   make bench          encode + wire + budgets -> bench/report.md
#   make bench-quick    same, few rounds (what CI runs)
#   make bench-encode   the encoder table only, straight from the binary
#   make bench-wire     the pty harness for one case
#   make bench-replay   replay recorded real frames (needs --record first)
#   make bench-ab REF=main   same-machine A/B, markdown report for the PR
#   make test           swift test (unit + micro benchmarks)
#   make selftest       draw the calibration pattern in this terminal

CONFIG  ?= --pane 137x44 --cell 17x33 --source 1920x1200
BENCH_ARGS ?=
KRD     := .build/release/krd

.PHONY: all build test selftest bench bench-quick bench-encode bench-wire bench-replay bench-ab clean

all: build

build:
	swift build -c release

test:
	swift test

selftest: build
	$(KRD) --selftest --pane 137x44 --cell 17x33 --source 1920x1200

bench:
	python3 bench/bench.py $(BENCH_ARGS)

bench-quick:
	python3 bench/bench.py --quick $(BENCH_ARGS)

bench-encode: build
	$(KRD) --bench $(CONFIG) $(BENCH_ARGS)
	@echo "\nfor the machine-readable version: $(KRD) --bench --json $(CONFIG)"

bench-wire: build
	python3 bench/wire.py --case $(or $(CASE),line) --seconds $(or $(SECONDS),3) \
	  --drain $(or $(DRAIN),0) -- $(KRD) --bench-wire $(or $(CASE),line) \
	  --fps 20 --seconds $(or $(SECONDS),3) $(CONFIG)

bench-replay: build
	$(KRD) --replay $(or $(DIR),/tmp/krd-frames) --bench

bench-ab:
	./bench/ab.sh $(if $(REF),--ref $(REF)) --reps $(or $(REPS),3) --rounds $(or $(ROUNDS),20)

clean:
	swift package clean
	rm -rf bench/results bench/report.md
