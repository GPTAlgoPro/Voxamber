# Voxamber Git workflow

Repository: private GitHub project owned by the signed-in user.

`dev` is the default branch locally and remotely. Ongoing work is committed and pushed to `dev`.

`main` contains released work. After a release's checks pass and its build is ready for distribution, merge that release from `dev` into `main` and push once. Keep development on `dev` afterwards. Bootstrap creates a minimal shared repository-policy commit on `main`; it does not label the current App as released.

Do not commit model weights, generated frameworks, build products, raw logs, keys or credentials. Public download manifests and source receipts make large dependencies reproducible.
