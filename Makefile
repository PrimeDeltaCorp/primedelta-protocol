.PHONY: build test clean

build:
	forge build

test:
	forge test

test-v:
	forge test -vvv

clean:
	forge clean
