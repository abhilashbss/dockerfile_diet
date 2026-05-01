I shrank my Next.js Docker image from 2,072 MB to 237 MB.

I didn't pick the winning Dockerfile. An autoresearch loop did.

Setup: pick one mutable artifact (Dockerfile), freeze a contract (HTTP 200 on /), pick a score (image size), queue 7 candidates, let a script ratchet main forward. Run it. Walk away.

7 minutes later:

  baseline (node:22)          2,072 MB
  → slim                      1,188 MB
  → alpine                    1,103 MB
  → multi-stage slim            900 MB
  → multi-stage alpine          814 MB
  → standalone slim             329 MB
  → standalone alpine           244 MB
  → distroless + standalone     237 MB

-88.55%. Every candidate landed. Every win merged itself.

The wins above are well-known patterns; a careful engineer would have found them by hand. The value of the loop is that it encodes the discipline I usually skip — write the contract first, never merge a non-win, log every experiment. End state: 7 commits on main, each with a one-line hypothesis, plus a CSV audit trail of exactly what I tried and why.

Anywhere there's one artifact + one contract + a measurable score, this pattern works.

Code, harness, candidates, full results:
{GITHUB_URL}

#Engineering #DevOps #Docker
