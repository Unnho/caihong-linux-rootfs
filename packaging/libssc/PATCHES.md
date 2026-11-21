# libssc patch series

`scripts/install-caihong-ssc-stage.sh` applies every `NNNN-*.patch` in this
directory, in filename order, on top of libssc 0.4.4 (source commit
`0cf77b93b55752da34dca2dcecc06fca8665184b`). Third-party patches keep their
original author and are otherwise unmodified.

| Patch | Source | Author | Purpose |
|---|---|---|---|
| `0001-per-operation-report-handler.patch` | Caihong | Osilvfe | Keep the report signal handler private to each open so concurrent opens cannot disconnect each other's listener. |
| `0002-sensor-allow-sample-rate-override.patch` | Armada OS `packages/libssc/patches/0002-...` | suckbluefrog | Add `ssc_sensor_set_sample_rate()` so a client can raise the 20 Hz rate SSC advertises for the QMI8658. |
| `0003-sensor-release-the-client-reference-taken-in-open-and-close.patch` | Armada OS `packages/libssc/patches/0003-...` | virtudude | `g_object_get()` in each sensor `open`/`close` leaked a reference to the client; release it. |
| `0005-sensor-log-a-failed-disable-before-handing-its-error-to-the-task.patch` | Armada OS `packages/libssc/patches/0005-...` | virtudude | `g_task_return_error()` may complete the task before it returns, so log `error->message` first to avoid a use-after-free. |

## Not applied

`0004-sensor-fail-an-open-that-is-never-confirmed.patch` (Armada OS) is
deliberately left out. It refuses a second concurrent open of the same sensor,
which contradicts the per-operation handler from `0001` and would fail
`test-concurrent-open.c`. Its useful parts — an open timeout and the
use-after-free handling around a failed enable request — need a rebase onto the
per-operation context first, and are tracked as a follow-up.
