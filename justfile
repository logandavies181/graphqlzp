alias b := build
@build:
    zig build

alias ti := testinstall
@testinstall: build
    cp zig-out/bin/graphqlzp ~/.local/bin

alias t := test
@test:
    zig test src/main_test.zig

alias f := fmt
@fmt:
    zig fmt .

@release:
    goreleaser release --clean
