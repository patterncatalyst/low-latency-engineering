# Low-Latency Engineering in C++, Python & Java

A chapter-based tutorial and book on latency engineering, with original examples
in C++20/23, Python 3.14 and Java 25 on Fedora 44. It runs from measurement and
code-level technique down to the real-time Linux kernel and CPU partitioning, and
out to transport choice by latency budget, low-overhead observability, and
failure handling.

The running workload is a high-speed parcel sortation line. Every technique is
measured against one end-to-end number: **scan-to-divert** latency.

Status: Parts 0 to 3 (chapters 0 to 10) are written, and their examples are measured. Parts 4 to 9 are planned.

## License

This project is dual-licensed to separate the code from the writing:

- **Code** — everything under `examples/`, plus build and helper scripts and
  inline code snippets — is licensed under the **Apache License 2.0**
  ([`LICENSE`](LICENSE)).
- **Content** — the tutorial and book prose (chapters under `_docs/`),
  diagrams and images under `assets/`, and the slide decks under
  `presentation/` — is licensed under **Creative Commons Attribution 4.0
  International (CC BY 4.0)** ([`LICENSE-docs.md`](LICENSE-docs.md)).

Copyright 2026 PatternCatalyst (Robert Sedor).

