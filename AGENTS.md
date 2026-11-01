# AGENTS.md

## Project

`gitlab-modes` is an Emacs package for GitLab merge requests and CI
pipelines.  One buffer shows one merge request or one pipeline.  A
separate mode shows a collection as a table.  Every display buffer
refreshes itself through `auto-revert-mode` and never blocks Emacs.

The package reads GitLab through the `glab` command line program.  The
Nix build substitutes `gitlab-program` with the store path of the
nixpkgs `glab` package.  The package has no native HTTP transport yet.
The git-bug issue `cabdead` holds the design for that backend.

The license is AGPL-3.0-or-later.  Read `LICENSE`.

## Files

| File | Purpose |
|---|---|
| `gitlab-modes.el` | Entry library and package namesake.  Requires the data layer, the display layer, the ID prompts and both resource families.  `(use-package gitlab-modes ...)` and `:ensure t` load and resolve through it.  An autoloaded form loads the evil layer at the load of evil and enables it. |
| `gitlab-error.el` | Package-wide parent condition `gitlab-error` and the `gitlab` customization group.  `gitlab-cli-error` and `gitlab-cli-timeout` cover the CLI transport.  `gitlab-api-error` and `gitlab-api-timeout` reserve the native transport.  `gitlab-backend-error` reports an unsupported backend. |
| `gitlab-cli.el` | glab transport: `gitlab-program`, `gitlab-repository`, `gitlab-cli-directory`, `gitlab-cli-timeout`, `gitlab-cli-request` (sync), `gitlab-cli-request-async`, `gitlab-cli-stream`, `gitlab-cli-project-endpoint`, the project.el directory helper, argument helpers.  JSON decodes to an alist with symbol keys.  JSON false decodes to `:false`; JSON null decodes to nil. |
| `gitlab-data.el` | Data layer: `gitlab-backend`, field accessors, the list cache, and the merge request, pipeline and job entry points.  No buffer, mode, face or key code.  `gitlab-backend` accepts `cli`; `api` signals `gitlab-backend-error`. |
| `gitlab-mode.el` | Display layer: customization, faces, the detail base mode, the list base mode, the asynchronous refresh pipeline, the stale check, the field and value renderers, imenu and the navigation commands. |
| `gitlab-read.el` | ID completion: `gitlab-read-merge-request-iid`, `gitlab-read-pipeline-id`, `gitlab-read-job-id`.  The prompts read the cached lists and accept a typed ID. |
| `gitlab-merge-request.el` | Merge request list mode, detail mode, display commands and the notes command. |
| `gitlab-pipeline.el` | Pipeline list mode, pipeline detail mode with the jobs table, and the streaming job log mode. |
| `gitlab-evil.el` | Optional evil layer: the global `gitlab-evil-mode`, the auto enable function, the option `gitlab-evil-auto-enable` and three local minor modes.  The package does not depend on evil. |
| `ol-gitlab.el` | Optional Org link types: `gitlab-mr:`, `gitlab-pipeline:` and `gitlab-job:`.  Follow, store and export. |
| `gitlab-xref.el` | Optional xref backend: `mr:`, `pipeline:` and `job:` identifiers.  Text properties win over a typed identifier. |
| `test/gitlab-test-helpers.el` | Shared ERT helpers: the mock program path, the environment macro and the process wait helper. |
| `test/mock-glab` | Offline glab stand-in.  It reads `test/fixtures` and never opens a network connection. |
| `test/fixtures/` | Minimal glab JSON, a job trace and a pipeline without a jobs array. |
| `*-tests.el` | ERT suites.  `package-build` excludes this suffix from the package and the lint gate skips it. |
| `flake.nix` | flake-parts flake with one `melpaBuild` for the whole repo, the glab store path patch, the evil load path for the install compile, the ERT check phase and the package-lint, checkdoc and treefmt checks.  The package goes through `lib.makeOverridable`, so `packages.default.override` swaps the Emacs package set, `melpaBuild`, the version, the glab store path or the evil package. |
| `flake.lock` | Pinned flake inputs. |
| `README.org` | User documentation. |
| `AGENTS.md` | This file. |
| `LICENSE` | AGPL-3.0. |

## Build and test

```sh
nix build          # package; its check phase byte-compiles and runs ERT
nix flake check    # package, package-lint, checkdoc, treefmt
nix fmt            # nixfmt via treefmt
nix develop        # emacs with evil, and glab
```

Without Nix:

```sh
emacs --batch -L . -L test -L "$EVIL" -l gitlab-test-helpers.el \
  -l gitlab-cli-tests.el -l gitlab-data-tests.el \
  -l gitlab-mode-tests.el -l gitlab-merge-request-tests.el \
  -l gitlab-pipeline-tests.el -l gitlab-read-tests.el \
  -l gitlab-evil-tests.el -l ol-gitlab-tests.el \
  -l gitlab-xref-tests.el -f ert-run-tests-batch-and-exit
```

`EVIL` is the directory that holds `evil.el`.  All other tests run
without evil.  The suite never opens a network connection.

## Conventions

- Dependencies point down only: transport (`gitlab-cli.el`), data
  (`gitlab-data.el`), presentation.  `gitlab-data.el` never opens a
  buffer, reads no buffer-local variable and loads no mode library.  A
  consumer that requires `gitlab-data` gets the data entry points.
- All reads go through the type-keyed data entry points.  A mode never
  builds a glab command by hand and never calls `gitlab-program`
  directly.  This keeps the planned `api` backend a transport swap.
- The data layer has a synchronous and an asynchronous form for every
  read.  The synchronous form serves prompts and tests.  The display
  buffers use the asynchronous form.  A fetcher returns its process
  object so `gitlab--kill-pending` can cancel it.
- JSON is an alist with symbol keys.  Read a field with
  `gitlab-data-field`; it compares strings and symbols.  Do not
  normalize the raw shape.  `:false` is JSON false and nil is JSON null.
  Use `gitlab-data-set-field` to merge a missing field, because the
  built-in `alist-get` setter does not mutate a non-empty list for a
  missing key.
- The data cache serves prompts only.  `gitlab-cache-ttl` controls it;
  `gitlab-cache-clear` and `gitlab-cache-invalidate` drop entries.  A
  display buffer fetches fresh data on every refresh.
- `gitlab-pipeline-show` and its asynchronous form read the jobs array
  from `glab ci get --output json`.  When the array is missing, the
  data layer fetches `projects/:id/pipelines/:pipeline_id/jobs` once and
  merges the answer.  The renderer always sees a `jobs` key.  The
  asynchronous form stores the follow-up process in the
  `gitlab-cli-follow-up` property of the first process, so a cancel
  stops both.
- The notes and jobs endpoints ask for `?per_page=100` and do not pass
  `--paginate`.  `--paginate` concatenates one JSON array per page, and
  one `json-parse-string` call cannot read that.  A collection with
  more than 100 items shows the first page only.
- `gitlab-cli-request` takes `PARSE` as `json` (the default) or `text`.
  A nil value means `json`.  The job trace uses `text`.
- The CLI process environment adds `GLAB_NO_PROMPT=1`.  A prompt would
  wait forever in batch Emacs.  Do not remove it.
- A synchronous `make-process` needs `:sentinel #'ignore`.  The default
  sentinel writes "Process ... finished" into the output buffer and
  corrupts JSON.  The asynchronous forms supply their own sentinel.
- `gitlab-cli--repository-arguments` appends `--repo` when
  `gitlab-repository` is set and the caller did not name one as
  `--repo`, `--repo=X`, `-R` or `-RX`.  The API endpoint helper
  URL-encodes a namespace path, or uses the `:id` placeholder for glab
  inference.
- `gitlab-cli-directory` selects the directory in which glab runs.  A
  nil value means `default-directory`, so a prompt runs in the project
  of the user.  Every process creation binds `default-directory` to
  `gitlab-cli-directory-of'.  `gitlab-cli--project-directory` asks
  project.el for the root of a directory and returns the directory
  itself when it belongs to no project.
- A stream has no timeout by default.  `gitlab-cli-stream` takes a
  TIMEOUT only when a caller wants one, because a job trace can run for
  hours.  The synchronous and asynchronous requests keep
  `gitlab-cli-timeout`.
- Errors signal a condition that derives from `gitlab-error`.  A public
  function documents the conditions it raises.  An asynchronous error
  callback receives a condition list, not a string.
- `gitlab--refresh` and `gitlab-list--refresh` share one pipeline.  An
  in-flight fetch sets `gitlab--pending`; a refresh during that fetch
  sets `gitlab--refresh-requested` and runs when the fetch completes.
  An unchanged answer (`equal`) is not rendered again.
- Both display modes wire `revert-buffer-function` to
  `gitlab--revert-buffer` and `buffer-stale-function` to
  `gitlab--buffer-stale-p`.  The revert function fetches the collection
  in a list buffer and the object in a detail buffer.  The stale
  check returns nil while a fetch runs and, with
  `gitlab-refresh-visible-only`, in a buffer that no window shows.
  `gitlab-refresh-fast-interval` applies while a status in
  `gitlab-transitional-states` shows.
- Display buffers are views.  `default-directory` is the project root
  of the buffer that opened the display, `buffer-modified-p` stays
  nil, and `kill-buffer` asks no question.  A new display path must
  call `gitlab--use-project-directory` and
  `(set-buffer-modified-p nil)`.
- A display buffer keeps the project root of the buffer that opened it
  in `gitlab-cli-directory`, because glab must run in the project.
  `gitlab--use-project-directory` sets both variables from the
  project.el answer.  Call it in `gitlab--prepare-detail`,
  `gitlab-list--show` and `gitlab-pipeline--prepare-job-log`, so a
  second display of the same buffer never captures an old project.
- `gitlab--prepare-detail` and `gitlab-pipeline--prepare-job-log`
  return a buffer without displaying it.  The xref backend uses them, so
  a definition never moves the window configuration.
- The renderers attach text properties.  `gitlab-field` names a field
  line.  `gitlab-pipeline-id`, `gitlab-merge-request-iid`,
  `gitlab-job-id` and `gitlab-url` are navigation targets.
  `gitlab-open-at-point` reads them.  A new object type adds one property
  and one branch there.
- The merge request detail renders every top-level JSON field.  Nested
  objects go through `gitlab--format-object`: a user becomes
  `Name (@username)`, a milestone its title, and an object with `id`
  and `status` becomes `#ID status`.  Only an object that also has
  `ref` or `sha` carries `gitlab-pipeline-id`; any other keeps the
  plain text or a `gitlab-url` link.  Empty strings and nil render as
  `-`.
- The pipeline detail uses a hand-written jobs table, not
  `tabulated-list-mode`, because the pipeline fields occupy the same
  buffer.  Every job row carries `gitlab-job-id` and `gitlab-job-name`.
  `gitlab-pipeline--render` restores point to the same job row or to
  the same field line.
- The job log streams `glab ci trace`.  `gitlab-cli-stream` inserts
  chunks into a read-only buffer, applies ANSI colors and clears the
  modified flag.  Killing the buffer deletes the process.  The buffer
  has no stale check.  `gitlab-job-log--start` erases the buffer first,
  so a second display of the same job never appends a second trace.
  `gitlab-job-log-restart` serves as `revert-buffer-function`, so it
  accepts and ignores the two `revert-buffer` arguments.
- List modes derive from `gitlab-list-mode`, which derives from
  `tabulated-list-mode`.  A derived mode sets
  `gitlab-list--fetch-function`, `gitlab-list--entries-function`,
  `gitlab-list--rows-function` and `gitlab-list--open-function`, and
  sets `gitlab-list--kind`.  The row ID is the merge request IID or the
  pipeline ID, so an update keeps point on the same row.
  `gitlab-change-functions` receives `gitlab-list--kind` and a nil ID
  for a list buffer, because one collection has no single ID.
- The list columns live in `gitlab-merge-request-list-format` and
  `gitlab-pipeline-list-format`.  Numeric columns use
  `gitlab-list--number-sort`.  A `tabulated-list` SORT predicate
  receives whole `tabulated-list-entries` elements, not the cell
  strings, so the helper reads the sorted column from the entry and
  strips the `!` of a merge request IID.
- Every face inherits a standard face and lives in `gitlab-mode.el`.
  Status faces come from `gitlab-status-faces`; do not apply a
  font-lock face in a renderer.
- Colors, dates and status values go through
  `gitlab--field-value-face`, `gitlab--format-date` and
  `gitlab-status-face`.  A new date field goes into `gitlab-date-fields`.
- Interactive entry points carry `;;;###autoload` cookies.  The
  optional layers keep their own files and are not required by
  `gitlab-modes.el`.
- `gitlab-evil.el` binds every command key through
  `evil-define-minor-mode-key`, one key set per state and local minor
  mode.  A key that evil already binds becomes a `[remap
  EVIL-COMMAND]` vector, so the binding follows the command and not
  the key, and a user who moves `evil-ret` elsewhere keeps the
  behaviour.  A key without an evil command, such as `gr`, stays a
  key string.  `gitlab-evil--key-sequence` passes a vector unchanged
  and parses a string.  Do not `require` evil at the top of the file:
  evil runs `evil-after-load-hook` before it provides its feature, so
  a plain `require` recurses there.  The file requires evil only when
  `evil-define-minor-mode-key` is absent, and it declares that
  function for the byte compiler.  Do not add evil to
  `Package-Requires` or `packageRequires`; the check phase and the
  `preInstall` compile put evil on the load path instead.
- `gitlab-modes.el` carries one autoloaded `add-hook` form for
  `evil-after-load-hook` and one plain `(when (featurep 'evil) ...)`
  form.  Together they load `gitlab-evil` and call the autoloaded
  `gitlab-evil-auto-setup`, which enables `gitlab-evil-mode` unless
  the option `gitlab-evil-auto-enable` is nil.  The hook covers a load
  of evil after this library, the plain form covers the other order.
  A user without evil loads nothing extra.  Do not use
  `with-eval-after-load` or `after-load-functions` here: package-lint
  warns about the first, and the second fired during a byte-compile
  scan and caused a recursive load.
- `ol-gitlab.el` registers the link types at load.  A `:store`
  function calls `org-link-store-props` and returns nil outside a
  GitLab buffer, because Org calls every store function in every
  buffer and a signal there breaks `org-store-link` for all link types.
  The export function writes a web URL when `gitlab-repository' is
  set, because the URL needs the project path: an HTML anchor, a
  markdown link, a LaTeX `\href`, and the text with the URL after it
  for every other backend.
- `gitlab-xref.el` registers its backend through an autoloaded
  `add-hook` form.  It accepts text properties first, then a typed
  `mr:`, `pipeline:` or `job:` identifier.  A merge request list cell
  shows `!IID`, so the backend strips the sigil before it names a
  buffer or a glab argument.
- Tests run offline.  Mock at the process level with `test/mock-glab`;
  never call a real GitLab.  A new command needs an ERT test and, when
  it adds a file, a line in `checkPhase` only if the glob misses it.
- Byte-compilation runs with warnings as errors.  Declare a function
  from another file with `declare-function` when the file does not
  require it.  The test helper marks its dynamically bound variables
  special at compile time.
- `checkdoc` and `package-lint` must pass through `checks.checkdoc` and
  `checks.package-lint`.  The package-lint check whitelists `gitlab`
  and `ol-gitlab` as shared prefixes.
- `nix fmt` formats `flake.nix`.  Do not run nixfmt standalone.
- `gitlabModes` in `flake.nix` calls `lib.makeOverridable` with one
  argument set: `emacs`, `emacsPackages`, `melpaBuild`, `version`,
  `glab` and `evil`.  The flake passes the commit-derived `version`, and
  the argument defaults to `"0.1.0"` for a plain import.  Every other
  dependency derives from `emacs`, so one override moves them all.  A
  new build input becomes a new named argument, not a hard-coded
  binding.

## TODO

- Native `api` backend.  The design is in git-bug issue `cabdead`:
  `url.el` transport, token discovery, pagination, cancellation and a
  parity test against the CLI fixtures.
- More filters for the list commands: state, scope, labels and author.
- Merge request discussions by discussion, not one flat notes list.
- Pipeline actions: retry, cancel and play a manual job.
- A second detail buffer for a job with its metadata, not only the log.
