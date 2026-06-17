# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue. Email the maintainer at the address listed in the GitHub profile, or use GitHub's private "Report a vulnerability" form on the [Security tab](https://github.com/skykery/keepers/security). I aim to acknowledge reports within 7 days and to ship a fix within 30 days for confirmed issues.

## Threat model

Keepers is a **single-user, local-only Mac app**. The threat model assumes:

- The user runs the app on their own machine.
- The user's photos are not malicious — they're shots from the user's own camera or trusted sources.
- The Flask HTTP server binds only to `127.0.0.1` and uses a random port (pywebview mode) or port 5000 (dev mode).
- An attacker may try to reach the local server through a malicious page in the user's browser (same-origin policy + DNS rebinding) or through a malformed image file.

Keepers is **not** designed for multi-user, sandboxed, or untrusted-photo workloads. Don't deploy it on a shared server.

## Hardened-runtime entitlements

The notarized `.app` ships with these entitlements relaxed in [`Entitlements.plist`](Entitlements.plist):

| Entitlement                                          | Why                                                        |
|------------------------------------------------------|------------------------------------------------------------|
| `com.apple.security.cs.allow-jit`                    | PyTorch's MPS backend JIT-compiles compute kernels.        |
| `com.apple.security.cs.allow-unsigned-executable-memory` | PyTorch and MediaPipe load compiled extensions at runtime. |
| `com.apple.security.cs.disable-library-validation`   | Lets us load Python C-extensions that aren't co-signed.    |
| `com.apple.security.cs.allow-dyld-environment-variables` | Required so we can point `HF_HOME` at the user model cache. |

These reduce the protection hardened runtime gives against runtime code injection. They are not avoidable while we bundle CPython + PyTorch + MediaPipe; a future Swift + CoreML rewrite would let us drop them.

## Models and the supply chain

On first launch Keepers downloads ~1 GB of model weights:

| Source                      | URL                                                                       | Integrity check                       |
|-----------------------------|---------------------------------------------------------------------------|---------------------------------------|
| HuggingFace (CLIP ViT-B/32) | `huggingface.co/openai/clip-vit-base-patch32`                             | LFS SHA256 via the HF Hub client      |
| HuggingFace (CLIP ViT-L/14) | `huggingface.co/openai/clip-vit-large-patch14`                            | LFS SHA256 via the HF Hub client      |
| GitHub (LAION predictor)    | `github.com/christophschuhmann/improved-aesthetic-predictor/raw/main/...` | SHA256 pinned in `models_download.py` |
| Google (MediaPipe landmark) | `storage.googleapis.com/mediapipe-models/.../face_landmarker.task`        | SHA256 pinned in `models_download.py` |

CLIP weights are loaded with `use_safetensors=True` to bypass the unsafe `torch.load(pickle)` path (CVE-2025-32434).

Each non-HF download is written to a `.part` file, hashed, and only renamed into place if the SHA matches. On mismatch the partial file is deleted and `ModelIntegrityError` is raised — the user sees the failure in the UI and the bad file never reaches the model loader. Updating either model version requires rotating the pinned hash in the same commit.

## Image parsing

Keepers decodes user-supplied images with **Pillow** (JPEG/PNG/WebP/TIFF) and **rawpy/libraw** (ORF/NEF/DNG/CR2/CR3/ARW/RW2/RAF). Both libraries have had CVEs for malformed-input parsing.

Mitigations:

- The threat model assumes the user's own photos. Don't point the app at images you wouldn't otherwise open.
- `requirements.txt` pins recent versions. Update when security advisories land.
- Flask is configured with `MAX_CONTENT_LENGTH = 16 MB` to cap unbounded upload-like memory growth.

## Recently fixed

- **Path traversal in filename-keyed endpoints.** Several `/api/...` routes passed user-supplied filenames straight into `originals_dir / filename`, allowing requests like `photo_name: "../../etc/passwd"` to read or write outside the session directory. A `_safe_filename()` guard now rejects anything that isn't a plain basename.
- **`debug=True` in `webapp.py` dev mode.** Flask's Werkzeug debugger is remote-code-execution by design. The dev launcher now reads `KEEPERS_DEBUG=1` to opt in; off by default.
- **No integrity check on LAION + MediaPipe downloads.** Both files are now verified against pinned SHA256s in `models_download.py`; mismatches raise `ModelIntegrityError` and delete the partial file.

## Known accepted risks

- **No CSRF tokens on the local API.** Browsers block cross-origin `application/json` POSTs via the SOP/CORS preflight, so a malicious page cannot trivially hit Keepers' endpoints. DNS rebinding is a residual risk; the pywebview launcher uses a random port to make it harder to target.
- **`/api/browse` enumerates directories.** Needed for the dev/browser fallback path. Not callable from a non-loopback origin under normal browser SOP rules.
- **No rate limiting.** Local single-user app; not a meaningful attack surface.

## Reviewing the code

The smallest interesting surfaces are:

- `webapp.py` — Flask routes, especially anything with `<filename>` or that reads JSON bodies.
- `models_download.py` — network fetches, file writes.
- `folder_manager.py` — symlink creation.
- `paths.py` — anywhere user data lives.

Independent review is welcome.
