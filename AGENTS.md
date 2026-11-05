# Voxamber repository workflow

- This project is a general on-device 3D modeling app. Do not constrain creation to buildings, furniture, or a fixed object category list. Examples are inspiration only.
- Product names: 维珀 / Voxamber. Bundle: `com.kaisun.voxamber`. Category: Productivity.
- Use native Swift, MLX, Metal, and Apple frameworks. Do not embed Python, JavaScript interpreters, or external script runtimes in the App.
- Target iPhone devices with at least 12GB RAM and adaptive iPhone Duo interfaces. On-device foundation models must remain in the 8B class or smaller; verify actual model suitability and performance rather than assuming newer or larger is better.
- `dev` is the local working branch and GitHub default development branch. Make ongoing development commits and pushes there.
- `main` is the release branch. Merge a verified release from `dev` and push `main` once per release; do not merge unfinished development into it. Initial repository setup is the only bootstrap exception.
- Keep model weights, build outputs, local caches, credentials, signing keys, provisioning profiles, and raw logs out of Git. Commit pinned public model manifests, source, licenses, tests, and sanitized verification receipts.
- Keep package tests, Simulator checks, real-device inference, offline acceptance, archive/upload, Apple processing, and TestFlight availability as separately evidenced states. Do not report one as proof of another.
