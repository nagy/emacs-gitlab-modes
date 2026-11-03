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
| `gitlab-modes.el` | Entry library and package namesake.  Requires the data layer, the display layer, the ID prompts, both resource families and the JSON export.  `(use-package gitlab-modes ...)` and `:ensure t` load and resolve through it.  An autoloaded form loads the evil layer at the load of evil and enables it. |
| `gitlab-error.el` | Package-wide parent condition `gitlab-error` and the `gitlab` customization group.  `gitlab-cli-error` and `gitlab-cli-timeout` cover the CLI transport.  `gitlab-api-error` and `gitlab-api-timeout` reserve the native transport.  `gitlab-backend-error` reports an unsupported backend. |
| `gitlab-cli.el` | glab transport: `gitlab-program`, `gitlab-repository`, `gitlab-cli-directory`, `gitlab-cli-default-host`, `gitlab-cli-timeout`, `gitlab-cli-request` (sync), `gitlab-cli-request-async`, `gitlab-cli-stream`, `gitlab-cli-project-endpoint`, `gitlab-cli-response-text`, the repository spelling (`gitlab-cli-repository-split`, `-path`, `-host`, `-normalize`), the project.el directory helper, argument helpers.  A stream takes an optional chunk filter.  JSON decodes to an alist with symbol keys.  JSON false decodes to `:false`; JSON null decodes to nil. |
| `gitlab-data.el` | Data layer: `gitlab-backend`, field accessors, the identifier syntax (`gitlab-data-identifier`, `gitlab-data-identifier-split`, `gitlab-data-identifier-signs`), the list cache, the session list `gitlab-repositories`, and the merge request, pipeline and job entry points.  No buffer, mode, face or key code.  `gitlab-backend` accepts `cli`; `api` signals `gitlab-backend-error`. |
| `gitlab-git.el` | Local Git reads: `gitlab-git-program`, `gitlab-git-use-magit`, `gitlab-git-commit-limit`, `gitlab-git-preferred-remote`, `gitlab-git-context-from-git`, the project context (`gitlab-git-remotes`, `gitlab-git-remote-url`, `gitlab-git-remote-context`, `gitlab-git-context`), ref discovery, the merge request commit range, the commit list, `gitlab-git-show-commit`, `gitlab-git-show-changes`, `gitlab-git-show-log`, `gitlab-git-patch-mode` and `gitlab-git-commit-mode`.  No network access and no repository writes. |
| `gitlab-mode.el` | Display layer: customization, faces, the detail base mode, the list base mode, the asynchronous refresh pipeline, the stale check, the field and value renderers, imenu, the navigation commands, the parent and sibling protocol, the bookmark records, `gitlab-bookmark-jump` and the `js-json-mode` remap of both base modes. |
| `gitlab-read.el` | ID completion: `gitlab-read-merge-request-iid`, `gitlab-read-pipeline-id`, `gitlab-read-job-id`, and the project prompt `gitlab-read-repository`.  The prompts read the cached lists and accept a typed ID. |
| `gitlab-merge-request.el` | Merge request list mode, detail mode, display commands, the notes command and the merge request list as the parent view of a detail buffer. |
| `gitlab-pipeline.el` | Pipeline list mode, pipeline detail mode with the jobs table, the job rows as the parent view of a job log, and the streaming job log mode. |
| `gitlab-export.el` | `gitlab-export-json`, the single JSON export buffer and the fallback encoder.  It installs no key. |
| `gitlab-evil.el` | Optional evil layer: the global `gitlab-evil-mode`, the auto enable function, the option `gitlab-evil-auto-enable` and three local minor modes.  The package does not depend on evil. |
| `ol-gitlab.el` | Optional Org link types: `gitlab-mr:`, `gitlab-pipeline:` and `gitlab-job:`.  Follow, store and export.  A path names its project with the bookmark identifier. |
| `gitlab-xref.el` | Optional xref backend: `mr:`, `pipeline:` and `job:` identifiers, with an optional project path.  Text properties win over a typed identifier. |
| `test/gitlab-test-helpers.el` | Shared ERT helpers: the mock program path, the environment macro and the process wait helper. |
| `test/mock-glab` | Offline glab stand-in.  It reads `test/fixtures` and never opens a network connection.  `GITLAB_TEST_TRACE` selects another job trace fixture. |
| `test/fixtures/` | Minimal glab JSON, a job trace, a job trace with sections and a pipeline without a jobs array. |
| `*-tests.el` | ERT suites.  `package-build` excludes this suffix from the package and the lint gate skips it. |
| `flake.nix` | flake-parts flake with one `melpaBuild` for the whole repo, the glab store path patch, the git check input, the evil load path for the install compile, the ERT check phase and the package-lint, checkdoc and treefmt checks.  The package goes through `lib.makeOverridable`, so `packages.default.override` swaps the Emacs package set, `melpaBuild`, the version, the glab store path, the git binary or the evil package. |
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
  -l gitlab-context-tests.el -l gitlab-mode-tests.el \
  -l gitlab-merge-request-tests.el \
  -l gitlab-git-tests.el -l gitlab-pipeline-tests.el \
  -l gitlab-export-tests.el \
  -l gitlab-read-tests.el -l gitlab-evil-tests.el -l ol-gitlab-tests.el \
  -l gitlab-xref-tests.el -l gitlab-bookmark-tests.el \
  -f ert-run-tests-batch-and-exit
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
- `gitlab-git.el` reads the merge request refs that the user already
  fetched.  It finds a ref by suffix, so both
  `refs/remotes/origin/merge-requests/IID/head` and
  `refs/merge-requests/IID/head` work.  The merge request IID must be
  digits only, because it becomes part of a ref name and a git
  argument.  A missing ref, a missing object or a failed command
  returns nil, so a display buffer shows no section instead of a
  signal.  The base comes from `diff_refs.base_sha`, then from
  `diff_refs.start_sha`, then from `git merge-base` against
  `target_branch`.
- `gitlab-git.el` never runs a command that writes to the repository
  and never opens a network connection.  It calls `git` through
  `process-file` with `GIT_OPTIONAL_LOCKS=0`, and it reads commit
  records with `%x00` separators.  A literal NUL in an Elisp string
  reaches `process-file` as the end of the argument.
- `gitlab-git-show-commit`, `gitlab-git-show-changes` and
  `gitlab-git-show-log` prefer Magit when `gitlab-git-use-magit` is
  non-nil and `(require 'magit nil t)` succeeds.  They call
  `magit-show-commit`, `magit-diff-range` and `magit-log-other`.
  Magit's own `E` reaches Ediff, so the package adds no second ediff
  code path.  Without Magit they open a read-only
  `gitlab-git-patch-mode` buffer, which derives from `diff-mode`, and
  `q` closes it.  Magit stays out of `Package-Requires` and out of the
  melpaBuild inputs.  Declare every Magit function with
  `declare-function`.
- `gitlab-merge-request-show-changes` on `d` and
  `gitlab-merge-request-show-log` on `l` pass `gitlab--id`,
  `gitlab--last-data` and the active commit selection to the Git
  layer.  Both signal a user error in a buffer without a local merge
  request ref.  The log covers `BASE..HEAD`, so Magit lists only the
  commits of the merge request.
- An active region over commit lines narrows `d` and `l`.
  `gitlab-merge-request--region-commits` collects the
  `gitlab-commit-sha` values from the region in display order.
  `gitlab-git-commit-selection-range` takes the newest selected commit
  as the head and the parent of the oldest selected commit as the
  base.  A selected root commit uses `git hash-object -t tree
  /dev/null`, so a SHA-256 repository gets its own empty tree.  A
  region without a commit line and a stale selected commit both fall
  back to the full merge request range.
- The merge request detail lists the local commits after the field
  table with `gitlab-commit-sha` on every line.  `gitlab-open-at-point`
  reads that property first.  A commit limit shows "N more commits."
  The section appears only with `gitlab-merge-request-show-commits`
  and a local merge request ref.
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
  `gitlab-cli-timeout`.  The last optional argument is a chunk filter:
  it receives the process and one chunk and writes the chunk itself, so
  the job log can assemble lines before it inserts them.
  `gitlab-cli--insert-chunk` inserts text, applies ANSI colors and
  clears the modified flag, and it returns the start position of the
  text.
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
- With `gitlab-refresh-finished-pipelines` (default t), the stale
  check also returns nil in a settled pipeline buffer.
  `gitlab--settled-p` reports a `pipeline` kind whose status is not in
  `gitlab-transitional-states` and whose `jobs` array holds no such
  status either.  A final pipeline cannot change without a user
  action.  A list buffer, a merge request buffer and a pipeline with a
  nil status keep polling, because a new object or a reopened
  collection can arrive.  A manual `revert-buffer` still fetches, so a
  restarted job shows again; the settle check then applies to the new
  answer.
- `gitlab-go-to-parent` walks one level up.  The buffer-local
  `gitlab--parent-function` names the command of each kind: a merge
  request opens `gitlab-list-merge-requests`, a pipeline opens
  `gitlab-list-pipelines` and a job log opens the pipeline that holds
  the job.  A list buffer leaves the variable nil, so the command
  signals `user-error` and `dired-jump` keeps its dired meaning there,
  because the directory of a list buffer is the project root.  The
  detail keymap and the job log keymap remap `dired-jump` and
  `dired-up-directory` to the command; `gitlab-evil.el` adds the same
  two remaps to its detail and job log key lists.
- `gitlab-next-sibling` and `gitlab-previous-sibling` walk inside one
  collection, and a numeric argument walks several entries at once.
  The parent view holds the order of its children, so a sibling
  command reads the open parent buffer and fetches no collection.  The
  child names its parent with `gitlab--parent-identity-function`, a
  function of no argument that returns the major mode function and
  the object ID of the parent, or nil.  A list parent passes nil as
  the ID.  `gitlab--parent-buffer` finds the parent by identity, so a
  renamed parent buffer still answers.  A parent detail mode sets
  `gitlab--children-function`, a function of no argument that returns
  `(ID . NAME)` entries in display order; a list buffer needs no such
  function, because `gitlab--children` reads its rendered rows through
  `tabulated-list-get-id`, so the sort column decides the order.  The
  child sets `gitlab--sibling-open-function`, a function of ID and
  NAME that opens one entry of its own kind, and
  `gitlab--parent-label`, the human name of the parent view for the
  error messages.  `gitlab--move-sibling` resolves the current
  position by identity and calls the opener.
- A closing sibling walk, a parent view that is not open, a current
  object that the parent view does not hold and a buffer without a
  parent all signal `user-error`; nothing wraps around.  A list buffer
  has no parent, so it has no siblings.  The detail keymap and the job
  log keymap bind `C-c C-n` and `C-c C-p` and the forward and back
  buttons `[mouse-9]` and `[mouse-8]`.  Evil leaves `C-c` unbound in
  its states and binds no side button, so no evil key list needs the
  commands; `gitlab-evil-tests.el` keeps that assumption checked.
- A job log stores its pipeline ID, so a sibling jump passes the
  pipeline and the job name of the new entry to `gitlab-display-job-log`
  and the new log can walk up without a request.  A pipeline detail
  buffer is both a child of its list and the parent of its jobs: its
  own siblings come from the pipeline list rows, and its children are
  its job rows.
- A sibling command opens the neighbour in its own buffer and leaves
  the buffer that it leaves open, so a job log keeps streaming and a
  walk back returns to the text that the buffer already holds.
- A job log knows its parent pipeline in three steps.  The pipeline
  detail buffer passes its own `gitlab--id` as the third argument of
  `gitlab-display-job-log`, the bookmark record stores the ID under
  `pipeline`, and `gitlab-job-log-pipeline-id` calls
  `gitlab-job-pipeline-id` once when neither holds it, then keeps the
  answer in `gitlab-job-log--pipeline-id`.  The data entry points
  `gitlab-job-show`, `gitlab-job-show-async` and
  `gitlab-job-pipeline-id` read the `pipeline` object of
  `glab api projects/:id/jobs/JOB_ID`.  So a log that a bookmark, an
  Org link or an xref definition opened still reaches its pipeline.
- Display buffers are views.  `default-directory` is the project root
  of the buffer that opened the display, `buffer-modified-p` stays
  nil, and `kill-buffer` asks no question.  A new display path must
  call `gitlab--use-project-directory`,
  `gitlab--update-list-buffers-directory` and
  `(set-buffer-modified-p nil)`.
- One project context names one project on one instance.  The context
  is `PATH` for `gitlab-cli-default-host` and `PATH@HOST` for another
  instance, and `gitlab-cli-repository-normalize` produces it from a
  path, a `PATH@HOST` string, an HTTP URL or a Git URL.  Do not add a
  second spelling: buffer names, `list-buffers-directory`, bookmarks,
  Org links and xref identifiers all use this one.
- The context comes from a set `gitlab-repository`, else from the URL of
  `gitlab-git-preferred-remote` of the project root when
  `gitlab-git-context-from-git` is non-nil.  `gitlab-git-context`
  applies both steps, `gitlab-git-remote-context` reads only the Git
  remote, and `gitlab-git-remote-url-p` rejects a remote that names a
  local path.  A remote read prefers the Magit functions when Magit is
  already loaded, because loading all of Magit for one `git config` read
  is not worth it, and it falls back to `git` otherwise.
- The context names the buffer.  A detail name puts the context in
  front of the sigil (`*GitLab MR group/project!12*`), and a list name
  appends it (`*GitLab Merge Requests group/project*`).  A resource
  file therefore passes a *namer* to `gitlab--prepare-detail`, a
  function of ID and context that returns the name, and
  `gitlab-list--show` takes a base name that
  `gitlab--contextual-name` completes.  A new kind adds one namer next
  to its buffer-name defcustom.
- The name is a convenience, not the identity.  A display buffer keeps
  `gitlab--identity`, a list of its major mode, its object ID and its
  context, and `gitlab--identity-buffer` finds an open buffer by that
  list.  A user can rename a buffer to anything and the display command
  still reuses it.  A new display path must set the identity through
  the same place that sets the mode.
- `gitlab--use-project-directory` takes an optional DIRECTORY and an
  optional REPOSITORY.  Pass the value of the caller, because a dynamic
  `let` of `gitlab-repository` loses to a buffer-local value of an
  earlier display in the same buffer.  The helper sets
  `default-directory`, `gitlab-cli-directory` (glab must run in the
  project), `gitlab-repository`, `gitlab--context` and
  `gitlab--context-local`, then remembers the context in
  `gitlab-repositories`.  Call it in `gitlab--prepare-detail`,
  `gitlab-list--show` and `gitlab-pipeline--prepare-job-log`, so a
  second display of the same buffer never keeps an old project.
- `gitlab--context-local` is non-nil when the context equals the remote
  of the buffer directory.  `gitlab--local-checkout-p` is the guard of
  the Git views: it is non-nil for a buffer without a context too,
  because that buffer means the directory the user opened it from.  A
  buffer of another project inserts no commit section, and `d` and `l`
  signal a user error instead of reading the refs of the wrong
  repository.
- The list commands prompt through `gitlab-read-repository` when
  `gitlab-git-context` names no project, so the package works outside a
  checkout.  The prompt completes from `gitlab-repositories` and from
  the current context, and its answer binds `gitlab-repository` around
  the display.  Do not prompt when a context exists: the C-u prefix
  already carries `--all` for merge requests and the extra glab flags of
  a pipeline list.
- `gitlab-cli--repository-arguments` passes `PATH` to `--repo` for the
  default instance and `https://HOST/PATH` for another one, because glab
  selects an instance from a URL.  `gitlab-cli-project-endpoint`
  URL-encodes the path alone, so the host never enters an API endpoint.
  `gitlab-web-url` builds `https://HOST` from the context and keeps
  `gitlab-web-base-url` for the default instance.
- `gitlab--update-list-buffers-directory` sets the buffer-local
  `list-buffers-directory` to `gitlab-data-identifier` of the project
  and the object ID, so `list-buffers` shows `group/project!12` for a
  merge request, `#` for a pipeline and `&` for a job log.  A list
  buffer has no object ID and gets the project context alone.  The
  project comes from the buffer-local `gitlab--context` that
  `gitlab--use-project-directory` set, so the helper reads no Git
  remote again and the value never comes from the buffer name.  A
  renamed buffer keeps its identifier.  `gitlab--render` calls the
  helper at its end, so the value follows a context change too.
  `gitlab-export--fill` copies the value of its source buffer, so the
  export and its source show one identifier.
- `gitlab--prepare-detail` and `gitlab-pipeline--prepare-job-log`
  return a buffer without displaying it.  The xref backend uses them, so
  a definition never moves the window configuration.  Both take the
  context of the caller, so a definition of another project opens the
  buffer of that project.
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
- A stream never moves point.  `gitlab-cli--insert-chunk` inserts
  through `save-excursion`, so `gitlab-job-log--start` puts point on
  the first line and the trace grows below it.  The log follows the
  tail only through `gitlab-job-log--tail-p`: point must sit at
  `point-max` of a buffer that already holds text, and both
  `gitlab-job-log--write` and `gitlab-job-log--flush` read that
  answer before they insert.  An empty buffer at its start therefore
  never counts as the tail, and a reader who moves away from the end
  keeps the place.  A transport that moved point itself would fight
  this policy.
- The job log installs a chunk filter, because a process filter
  receives arbitrary chunks.  `gitlab-job-log--write` joins the tail of
  the previous chunk (`gitlab-job-log--pending`), so a line that a
  chunk cut in two reaches the buffer as one line.  Both callbacks of
  the stream flush the pending tail.  The filter drops the banner that
  `glab ci trace` prints on every run ("Getting job trace..." and
  "Showing logs for NAME job #ID."), and the empty lines before the
  first trace line, so the header line is the only place that names the
  job.
- GitLab prefixes a trace line with an ISO 8601 timestamp and a stream
  identifier (00O, 01O, 01E, 00O+) when the job enables runner
  timestamps.  `gitlab-job-log--apply-timestamps` marks the whole
  prefix with the text property `gitlab-job-log-timestamp` and hides
  it with the `invisible` property
  `gitlab-job-log--hidden-prefix` when
  `gitlab-job-log-show-timestamps` is nil.  Do not hide the prefix
  with `display ""`: Emacs then draws the cursor at the end of the
  previous line when point sits at the start of the line, so
  `move-beginning-of-line` on `0` and `C-a` looks like a motion to the
  line above.  `gitlab-job-log-mode` adds the symbol to
  `buffer-invisibility-spec`, so a custom spec hides the prefix too.
  The hidden range ends at
  `gitlab-job-log--prefix-end`: the stream identifier from
  `gitlab-job-log--stream-regexp` plus its one separator, or the one
  separator of the timestamp when no identifier follows.  The text of
  the line then starts at column 0, and every further space stays,
  because such a space belongs to the text.  The text stays in the
  buffer, so `gitlab-job-log-toggle-timestamps`, bound to `~` and to
  the evil remap of `evil-invert-char`, never fetches again.  The
  prefix is marked after the ANSI conversion, because a trace line
  starts with the escape sequences of the server.
- A copy of a region in a job log holds the text that the buffer
  shows.  `gitlab-job-log-mode` sets
  `filter-buffer-substring-function` to
  `gitlab-job-log--filter-buffer-substring`, so `kill-region`,
  `kill-ring-save` and the clipboard all receive the filtered string.
  `gitlab-job-log--replaced-ranges` collects the ranges that carry a
  `gitlab-job-log-section-start`, a `gitlab-job-log-section-end`, an
  `invisible` property or a string `display` property.  They cover a
  hidden timestamp prefix, the text of a section header and the text
  of an end marker, so a visible prefix reaches the copy and a hidden
  one does not.  The ranges also keep
  the face properties of the text that stays.
  `gitlab-job-log--strip-replaced` drops a line that keeps no text
  together with its newline, because a hidden end marker would
  otherwise leave an empty line.  Do not filter at
  `kill-transform-function`: that variable holds one global function
  and not a hook list, and it runs for every buffer.  A kill command
  in the read-only log copies and signals `buffer-read-only` through
  the usual `kill-region` fallback, so the trace text stays in place.
- A job log shows the duration of the active region on the right edge
  of the mode line.  `gitlab-job-log--region-span` reads the first and
  the last trace line in the region that carries a timestamp and
  returns their count and their difference.  A line without a
  timestamp neither starts nor ends the span, and fewer than two
  stamped lines leave the section off.  The helper reads
  `region-beginning` and `region-end` into locals before it moves
  point: `region-end` reads point and the mark, so a region that
  starts above and ends below would otherwise collapse to its first
  line.  The section appears only
  while `use-region-p` holds and
  `gitlab-job-log-show-region-duration` is non-nil.
  `gitlab-job-log--mode-line-format-base` reads the default mode line
  and drops a trailing `mode-line-end-spaces`, because that construct
  fills the rest of the line and would push the section past the
  right edge.  The mode keeps that list in
  `gitlab-job-log--mode-line-base`, and
  `gitlab-job-log--mode-line-format` appends the text to it.  Add the
  literal symbol `mode-line-format-right-align` only when the base
  format does not hold one: `mode--line-format-right-align` reads the
  first such symbol of `mode-line-format` and right-aligns every
  construct behind it, so a second symbol aligns the section against
  itself and pushes the whole right block off the edge.  A user format
  with its own right block therefore needs the plain text alone.
  `post-command-hook` and the chunk
  filter call `gitlab-job-log--mode-line-maybe-update`, which rebuilds
  the format only when the region signature changes.  The signature
  holds the region bounds and `buffer-chars-modified-tick`.  The
  hidden timestamp text stays in the buffer, so the section measures
  a region while `gitlab-job-log-show-timestamps` is nil.  Do not put
  `mode-line-format-right-align` in an `:eval` form: `format-mode-line`
  reads the symbol as a variable and the alignment stops working.
- GitLab writes `section_start:UNIX:NAME[collapsed=true]` before a
  section of a job and `section_end:UNIX:NAME` after it.
  `gitlab-job-log--section-regexp` reads both, and
  `gitlab-job-log--apply-section` runs from `gitlab-job-log--insert-line`
  after the ANSI conversion.  The start marker becomes a header, a
  `display` property of `── NAME (DURATION, N lines) ── ` with the
  `gitlab-title` face, and the anchor message of GitLab stays behind
  it on the same line.  The depth of a section is the length of the
  open stack at its start marker, and the entry keeps it, because
  the close renders the header again with the duration and the line
  count.  `gitlab-job-log--section-header` puts
  `gitlab-job-log--indent-width` spaces per level in front of the
  header, so a reader sees the parent of a nested section.  Only the
  header shifts: a body line keeps column 0, so a copy of the trace
  keeps its shape.  The line from its start up to the end of the
  marker also carries the property `gitlab-job-log-section-start`,
  and the name of the section is the property
  `gitlab-job-log-section-name` of the same range.  The helper reads
  the marker before it deletes the carriage returns of the line,
  because a carriage return ends the name and keeps the message that
  follows it out of the name.
  The duration comes from the two UNIX times of the markers, so
  no request is needed.  `gitlab-job-log--duration-string` keeps at
  most three decimals and drops trailing zeroes, so a whole second
  reads `27s` and not `27.000s`.  The end marker text gets
  `display ""` and
  the property `gitlab-job-log-section-end`, and the newline above
  it goes, so the marker joins the line before it.  A marker on a
  line of its own would hide a newline inside a folded section, and
  Emacs then draws the header of the next section on the header
  line of the folded one.  The close counts the trace lines between
  the two markers with `gitlab-job-log--section-line-count` before
  the join, because the join deletes a newline.  The count leaves
  the line of the start marker out and keeps every line between,
  so a blank line and the line of a nested section count.  The
  close writes the duration into the property
  `gitlab-job-log-section-duration` and the count into the property
  `gitlab-job-log-section-lines` of the start marker, so a later
  imenu entry needs no end marker.
  `gitlab-job-log--apply-timestamps` skips a line that starts with
  `gitlab-job-log-section-end`, so the timestamp toggle never shows
  part of a hidden end marker.  A start marker covers its leading
  carriage return and escape sequence, because glab passes them
  through.
  GitLab ends a trace line with a carriage return and an erase
  sequence, which a terminal uses to overwrite the line.  The ANSI
  conversion drops the escape sequence and leaves the carriage
  return, which a reader sees as ^M.
  `gitlab-job-log--delete-trailing-carriage-returns` removes the
  trailing carriage return of every inserted line, and
  `gitlab-job-log--delete-carriage-returns` removes every carriage
  return of a section marker line, so a header and a hidden end
  marker keep no ^M.
- The job log folds sections with `outline-minor-mode`, not with an
  overlay package.  `outline-regexp` is
  `gitlab-job-log--section-heading-regexp`, which matches the raw
  marker behind the timestamp prefix, so folding works while the
  prefix stays hidden.  `gitlab-job-log-toggle-section` on `TAB` calls
  `outline-toggle-children` at the enclosing heading, so it folds from
  any line of a section.  `S-TAB`, the `C-c @` prefix and the evil
  folds `zc`, `zo` and `za` come from `evil-fold-list`.  New text
  inherits text properties from the line above, so
  `gitlab-job-log--insert-line` removes `invisible`, `display`,
  `gitlab-job-log-section-start`, `gitlab-job-log-section-name`,
  `gitlab-job-log-section-duration`, `gitlab-job-log-section-lines`
  and `gitlab-job-log-section-end`
  from the inserted range first.
  `gitlab-job-log--reveal-open-section` opens the section that the
  new output enters, so a live trace never hides behind a fold.
- A restart erases the buffer, so `gitlab-job-log--start` calls
  `gitlab-job-log--collapsed-names` first and stores the folded names
  in `gitlab-job-log--collapsed`.  A section that the new trace closes
  folds again when its name is in the list.  Both
  `gitlab-job-log--collapsed` and `gitlab-job-log--sections` are
  `permanent-local`, because the mode runs again on a second display
  of the same buffer, and both stay in the buffer: no file, no
  custom variable, no session state.
- `gitlab-job-log--section-starts` walks the property
  `gitlab-job-log-section-start`, so it finds every section even
  when a marker shares its line with the marker of a neighbour.
  `gitlab-job-log--imenu-index` lists every start marker with the
  `gitlab-job-log-section-name` of the marker and, once the end
  marker arrived, the `gitlab-job-log-section-duration` and the
  `gitlab-job-log-section-lines`.  A section
  that still streams shows its name alone.
  `gitlab-job-log--collapsed-names` reads the same property list and
  asks `outline-invisible-p` at the heading line, so a name never
  comes from a search of the buffer text.
- List modes derive from `gitlab-list-mode`, which derives from
  `tabulated-list-mode`.  A derived mode sets
  `gitlab-list--fetch-function`, `gitlab-list--entries-function`,
  `gitlab-list--rows-function` and `gitlab-list--open-function`, and
  sets `gitlab-list--kind`.  The row ID is the merge request IID or the
  pipeline ID, so an update keeps point on the same row.
  `gitlab-change-functions` receives `gitlab-list--kind` and a nil ID
  for a list buffer, because one collection has no single ID.
- `gitlab-list-mode` appends a `url` provider to
  `thing-at-point-provider-alist`.  `gitlab-list--thing-at-point-url`
  returns the `web_url` field of `gitlab-list--row-at-point`, so
  `thing-at-point 'url` and `browse-url-at-point` answer with the
  upstream URL of the object on the current line.  The provider
  returns nil on a line without a row, and `thing-at-point` then falls
  back to its own scan.  `gitlab-list-open-web` and the provider share
  that function, so `w` and `thing-at-point` never disagree.
- The list columns live in `gitlab-merge-request-list-format` and
  `gitlab-pipeline-list-format`.  Numeric columns use
  `gitlab-list--number-sort`.  A `tabulated-list` SORT predicate
  receives whole `tabulated-list-entries` elements, not the cell
  strings, so the helper reads the sorted column from the entry and
  strips the `!` of a merge request IID.  A date column goes through
  `gitlab-list--date-cell`, so the cell carries `gitlab-date`.
- A list buffer shows the column names of `tabulated-list-format'
  in its header line, with the sort column marked by
  `tabulated-list-sort-key'.  `gitlab-list--render' calls
  `tabulated-list-init-header' after `tabulated-list-print', because
  the printer alone sets no header, and keeps the answer in
  `gitlab--header-line-format'.  `gitlab--set-error' replaces the
  header line of a detail buffer, and `gitlab--clear-error' restores
  `gitlab--header-line-format`.  A list error goes to
  `mode-line-process`, because the header line belongs to the table.
  Do not set a `:eval' entry in `header-line-format` of a list mode:
  it replaces the column names.
- `gitlab-export-json` exports the answer of the current display
  buffer.  The transport binds `gitlab-cli-response-text` around an
  asynchronous SUCCESS callback, and the refresh pipeline stores that
  raw text in the buffer-local `gitlab--raw-text`.  The export uses the
  raw text, so it matches `glab ... --output json` byte for byte.  A
  fetch that merges two answers sets `gitlab--raw-text` to nil, and the
  export encodes `gitlab--last-data` with `json-false` bound to
  `:false`.  One buffer, named by `gitlab-export-json-buffer-name`,
  serves every export.  It stays read-only, unmodified and a snapshot.
  Both display base modes remap `js-json-mode` to the command, and the
  job log mode does not, because a trace has no JSON answer.  The
  remap lives in `gitlab-mode.el` and not in `gitlab-export.el`: an
  autoloaded display command loads the display layer alone, so a key
  that `gitlab-export` installs at its own load never appears.  The
  remap target stays the symbol, so the first key that reaches it
  loads the export layer through its autoload cookie.
- Every face inherits a standard face and lives in `gitlab-mode.el`.
  Status faces come from `gitlab-status-faces`; do not apply a
  font-lock face in a renderer.
- Colors, dates, identifiers and status values go through
  `gitlab--field-value-face`, `gitlab--format-date` and
  `gitlab-status-face`.  A new date field goes into
  `gitlab-date-fields`; a new identifier field goes into
  `gitlab-id-fields`, so `id`, `iid`, `project_id`, `sha` and
  `before_sha` share `gitlab-id`.
- Interactive entry points carry `;;;###autoload` cookies.  The
  optional layers keep their own files and are not required by
  `gitlab-modes.el`.
- An interactive function that works in one mode names that mode in its
  `interactive` form, `(interactive nil gitlab-detail-mode)`, so `M-S-x`
  and `C-h m` list it in that mode alone.  A display command that
  starts a mode names no mode, because a user calls it from anywhere.
  `gitlab-go-to-parent`, `gitlab-next-sibling` and
  `gitlab-previous-sibling` name both `gitlab-detail-mode` and
  `gitlab-job-log-mode`; `gitlab-export-json` names both base modes.
  `command-modes` returns the list, and the suites assert it.
- `gitlab-evil.el` binds every command key through
  `evil-define-minor-mode-key`, one key set per state and local minor
  mode.  A key that evil already binds becomes a `[remap
  EVIL-COMMAND]` vector, so the binding follows the command and not
  the key, and a user who moves `evil-ret` elsewhere keeps the
  behaviour.  A key without an evil command, such as `gr`, stays a
  key string.  `gitlab-evil--key-sequence` passes a vector unchanged
  and parses a string.  `gitlab-job-log-toggle-timestamps` takes the
  `evil-invert-char` remap, so `~` toggles the timestamps of a job log
  in normal state.  `gitlab-job-log-toggle-section` takes the plain
  `TAB` key, because evil binds no fold command to it, and the evil
  fold keys `zc`, `zo` and `za` reach the same sections through
  `evil-fold-list` and `outline-minor-mode`.  `gitlab-export-json`
  takes the `evil-yank` remap, so `y` exports the JSON of a detail
  buffer or of a list buffer in normal state, and visual state keeps
  the ID copy.  Do not
  `require` evil at the top of the file:
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
- One identifier syntax names one object.  `gitlab-data-identifier`
  builds `REPOSITORY<SIGIL>ID` and `gitlab-data-identifier-split`
  parses it back; the sigils come from `gitlab-data-identifier-signs`
  (`!` merge request, `#` pipeline, `&` job).  A GitLab project path
  holds letters, digits, dots, hyphens and underscores only, so a
  sigil never appears in a path.  A text without the sigil is a bare
  ID, so an older Org link or bookmark keeps its meaning, and
  `gitlab-web-url` takes the repository as an optional third argument.
  Bookmarks, Org links and xref use this syntax in all three places;
  do not add a second spelling.  `string-trim` takes a regexp, so trim
  both ends with `"/+"` twice, not with one `"/"`.
- Bookmarks live in the display layer, so every user has them without
  a load step.  `gitlab--init-display-buffer` sets
  `bookmark-make-record-function` to `gitlab--bookmark-make-record`,
  and `gitlab-job-log-mode` sets its own wrapper because it does not
  run the display base mode; the wrapper adds the job name, and the
  pipeline ID when the buffer knows it.
  `gitlab--bookmark-make-record` stores `kind`, `id`, `location`,
  `repository`, `directory` and `target`, plus `arguments` and `sort`
  for a list buffer.  The kind of a list buffer is the collection kind
  with a `-list` suffix, and `gitlab--bookmark-base-kind` gives the
  object kind back.  A new bookmarkable kind needs one entry in
  `gitlab--bookmark-labels`, one in `gitlab--bookmark-link-types` and
  one `pcase` branch in `gitlab-bookmark-jump`.
- A target names a field line, a job row or a list row, never a buffer
  position, because the first render erases the buffer and moves point
  to its start.  `gitlab--goto-property` and `gitlab-list--goto-id`
  find the target again, and both fall back to `point-min` when the
  object is gone.  `gitlab--target` belongs to the display buffer, so a
  jump binds the dynamic `gitlab--pending-target` and
  `gitlab--init-display-buffer` copies it; the handler must not
  `setq-local` in the caller.  `gitlab--apply-target` runs at the end
  of `gitlab--render` and clears the target, so a later auto refresh
  keeps point through the text property instead of jumping back.
  `gitlab-bookmark-jump` restores the project and the directory by
  binding `gitlab-repository` and `gitlab-cli-directory`, then
  dispatches on the kind and sets `bookmark-handler-type` for the type
  column of `bookmark-bmenu`.
- Tests run offline.  Mock at the process level with `test/mock-glab`;
  never call a real GitLab.  A new command needs an ERT test and, when
  it adds a file, a line in `checkPhase` only if the glob misses it.
  The export tests compare the export buffer with the fixture text, so
  a raw answer must survive the fetch unchanged.
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
  `glab`, `git` and `evil`.  The flake passes the commit-derived
  `version`, and
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
- Job rows in the imenu of a pipeline buffer.  The design is in
  git-bug issue `01e1ede`: keep the field lines and add one entry per
  job row.
