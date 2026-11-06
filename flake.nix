{
  description = "Emacs modes for GitLab merge requests, work items and CI pipelines (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure, no duplicates.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    let
      # Date of the last commit as YYYY-MM-DD, folded into the version
      # string below.  The flake source info gives e.g. "20261031220000",
      # so slice out the year, month and day.
      lastModifiedDate = inputs.self.lastModifiedDate or "19700101000000";
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # The treefmt module provides the `formatter' output and a
      # `checks.<system>.treefmt' gate for `nix flake check'.
      imports = [ treefmt-nix.flakeModule ];

      # Emacs packages are pure Elisp, so evaluate on every Linux arch.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          version = "0.1.0-unstable-${commitDate}";

          # The package stays overridable, so a consumer can swap the
          # Emacs, its package set, the build function, the glab store
          # path or the optional evil package:
          #   inputs.gitlab-modes.packages.${system}.default.override {
          #     glab = pkgs.glab-custom;
          #   }
          # The flake passes the commit-derived version, because a plain
          # import of the expression cannot know it.
          gitlabModes = lib.makeOverridable (
            {
              # One Emacs package set supplies every dependency, so an
              # override of this argument moves all of them.
              emacs ? pkgs.emacs,
              emacsPackages ? emacs.pkgs,
              melpaBuild ? emacsPackages.melpaBuild,
              version ? "0.1.0",
              # The package shells out to glab at runtime.  Bake the store
              # path into the defcustom, so the installed package works
              # without anything on PATH.
              glab ? pkgs.glab,
              # The local Git tests build scratch repositories, so the
              # check phase needs git.  A consumer can swap the binary.
              git ? pkgs.git,
              # The optional gitlab-evil.el layer needs evil to compile and
              # test, but the package must not depend on it.  The check
              # phase supplies the elisp directory on the load path only.
              evil ? emacsPackages.evil,
            }:
            melpaBuild {
              # The package name matches its entry library, gitlab-modes.el,
              # so `(use-package gitlab-modes :ensure t)' resolves it.
              pname = "gitlab-modes";
              inherit version;

              src = lib.cleanSource ./.;

              # The shared gitlab-cli.el shells out to glab; bake its store
              # path in so the default value works out of the box.
              postPatch = ''
                substituteInPlace gitlab-cli.el \
                  --replace-fail 'gitlab-program "glab"' 'gitlab-program "${lib.getExe' glab "glab"}"'
              '';

              # The optional gitlab-evil.el layer needs evil to compile, but
              # the package must not depend on it.  The default install phase
              # compiles the packaged files with -Q, so preInstall puts the
              # evil elisp directory on EMACSLOADPATH for that compile.
              # Users without evil only see one "Cannot open load file" line
              # during their own package compile.
              preInstall = ''
                evil_dir=$(find ${evil}/share/emacs/site-lisp/elpa \
                  -mindepth 1 -maxdepth 1 -type d -name 'evil-*' -print -quit)
                export EMACSLOADPATH="$evil_dir:''${EMACSLOADPATH-}"
              '';

              # Byte-compilation warnings fail the build.  Keep it on: it is
              # the cheapest lint the package gets.
              turnCompilationWarningToError = true;

              doCheck = true;
              # The local Git tests build scratch repositories, so the
              # check phase needs git on PATH.
              nativeCheckInputs = [ git ];
              # No file lists here: the phase globs the tree.  Test files
              # carry the `-tests.el' suffix, which package-build excludes
              # from the tarball and the lint gate excludes from the ELPA
              # policy checks.
              checkPhase = ''
                runHook preCheck

                evil_load_path=$(find ${evil}/share/emacs/site-lisp/elpa \
                  -mindepth 1 -maxdepth 1 -type d -name 'evil-*' -print -quit)

                # The mock program carries a portable #!/usr/bin/env bash
                # line for the developer shell.  The build sandbox has no
                # /usr/bin/env, so rewrite the interpreter to the store path.
                patchShebangs test/mock-glab

                echo '=== byte-compile ==='
                for file in *.el; do
                  emacs --batch -L . -L test -L "$evil_load_path" \
                    --eval '(setq byte-compile-error-on-warn t)' \
                    -f batch-byte-compile "$file"
                done

                echo '=== ERT tests ==='
                test_args=(-l gitlab-test-helpers.el)
                for file in *-tests.el; do test_args+=(-l "$file"); done
                emacs --batch -L . -L test -L "$evil_load_path" \
                  "''${test_args[@]}" \
                  -f ert-run-tests-batch-and-exit

                runHook postCheck
              '';

              meta = {
                description = "Emacs modes for GitLab merge requests, work items and CI pipelines";
                longDescription = ''
                  A read-only Emacs interface to GitLab merge requests, work
                  items and CI pipelines.  One buffer shows one merge request,
                  one work item or one pipeline, and a separate mode shows a
                  collection as a sortable table.

                  A pipeline detail buffer renders the pipeline fields at
                  the top and its jobs table below.  RET on a job streams
                  the job trace into another buffer.  The merge request
                  detail buffer shows every glab JSON field and loads notes
                  on demand.  A work item detail buffer shows every field
                  of the issue that GitLab now calls a work item.

                  Both detail and list buffers refresh themselves through
                  auto-revert-mode.  The buffer-stale-function throttles
                  the poll, and the fetch runs asynchronously, so Emacs
                  never waits for the network.

                  gitlab-export-json writes the glab JSON answer of the
                  current buffer into one reusable read-only buffer.

                  The package talks to GitLab through the glab command line
                  program (nixpkgs package glab).  The build substitutes
                  the default value of gitlab-program with the store path
                  of that program.
                '';
                license = lib.licenses.agpl3Plus;
                homepage = "https://github.com/nagy/emacs-gitlab-modes";
                maintainers = with lib.maintainers; [ nagy ];
                platforms = lib.platforms.unix;
              };
            }
          ) { inherit version; };

          # Shell snippet for the ELPA policy checks: copy the packaged
          # Elisp sources into the build directory.  Test files carry the
          # `-tests.el' suffix and stay out.
          lintFiles = ''
            export HOME=$TMPDIR
            mode_files=()
            for file in "$src"/*.el; do
              case "$file" in
                *-tests.el) continue ;;
              esac
              cp "$file" .
              mode_files+=("$(basename "$file")")
            done
          '';
        in
        {
          # One canonical formatting config: `nix fmt' runs nixfmt, and
          # `nix flake check' rebuilds the treefmt check.
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };

          packages.gitlab-modes = gitlabModes;
          packages.default = gitlabModes;

          # `nix flake check' builds the package, so the check phase
          # (byte-compile with warnings as errors, full ERT suite) gates
          # the whole repo rather than only `nix build'.
          checks.package = gitlabModes;

          # package-lint: ELPA policy (headers, symbol prefixes,
          # dependency declarations).
          checks.package-lint =
            pkgs.runCommandLocal "gitlab-modes-package-lint"
              {
                nativeBuildInputs = [
                  (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                ];
                src = ./.;
              }
              ''
                ${lintFiles}

                # package-lint assumes online ELPA and wants symbols to
                # carry the file-name prefix.  The package shares the
                # shorter `gitlab-' prefix across every file, and the
                # optional Org link file uses `gitlab-org-'.  Whitelist
                # both.
                emacs --batch -l package-lint \
                  --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|\\`gitlab\\|\\`ol-gitlab"))' \
                  -f package-lint-batch-and-exit \
                  "''${mode_files[@]}"

                touch $out
              '';

          # checkdoc: docstring conventions, which byte-compilation cannot
          # check.
          checks.checkdoc =
            pkgs.runCommandLocal "gitlab-modes-checkdoc"
              {
                nativeBuildInputs = [ pkgs.emacs ];
                src = ./.;
              }
              ''
                ${lintFiles}

                # checkdoc exits 0 even on findings — gate on non-empty output.
                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(setq checkdoc-arguments-in-order-flag t)' \
                  --eval "(mapc #'checkdoc-file command-line-args-left)" \
                  "''${mode_files[@]}" 2>&1)
                if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                touch $out
              '';

          devShells.default = pkgs.mkShell {
            # Mirror whatever the package needs at runtime when hacking on
            # it: the external CLI and a real Emacs for interactive
            # testing.  Evil comes along for the optional gitlab-evil.el
            # layer.
            packages = [
              # The store path that the package bakes in, so the shell runs
              # the same binary as the built package.
              pkgs.glab
              pkgs.git
              (pkgs.emacsPackages.emacsWithPackages (p: [
                p.evil
                p.magit
              ]))
            ];
          };
        };
    };
}
