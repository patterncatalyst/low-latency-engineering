---
title: "Examples"
layout: plan
permalink: /examples/
description: "Every runnable example in this repo, mapped to the chapter it supports."
---

Every hands-on chapter has a matching runnable example under
[`examples/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples)
in the repo, laid out as `examples/NN-name/{cpp,python,java}/` with a `README.md`
that states the expected effect and how to verify it. Each example drives the shared
line simulator, reports a latency distribution (p50 / p99 / p99.9), and records the
machine or VM profile next to every number.

No examples have shipped yet. The first ones land with Part 0 and Part 1; see the
[roadmap]({{ '/plans/iteration-plan/' | relative_url }}).

| Example | What it shows | Languages | Chapter |
|---|---|---|---|
