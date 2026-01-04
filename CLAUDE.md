# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zupernes is a SNES (Super Nintendo Entertainment System) emulator project.

## Repository Structure

- `test/snes-test-roms/` - SNES test ROMs for verifying emulator accuracy, including:
  - DMA bug tests (`scpu-a-dma-bug-*.sfc`)
  - HDMA glitch tests (`hdma-*.sfc`)
  - INIDISP (display register) tests (`inidisp_*.sfc`)
