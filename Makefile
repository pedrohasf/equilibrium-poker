.PHONY: all core app run test bench-cli clean

all: app

core:
	cd core && cargo build --release

app: core
	./scripts/build-app.sh

run: app
	open build/Equilibrium.app

test: core
	cd core && cargo test --release
	cd app && swift test

bench-cli: core
	cd app && swift build -c release --product eqbench
	@echo "→ app/.build/release/eqbench"

clean:
	cd core && cargo clean
	rm -rf app/.build build
