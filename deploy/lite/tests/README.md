# deploy/lite/tests — smoke tests against the lite image

- `concurrent-bots.sh` — a concurrency smoke test: ≥2 concurrent bots must reach `joining` on
  per-bot profile dirs with zero Chromium SingletonLock signatures. Run against a running
  `make lite` stack:

  ```bash
  deploy/lite/tests/concurrent-bots.sh
  ```
