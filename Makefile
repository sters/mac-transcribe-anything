.PHONY: build lint format

build:
	swift build -c release

lint:
	swift format lint --strict --recursive Sources Package.swift

format:
	swift format format --in-place --recursive Sources Package.swift
