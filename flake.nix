{
  description = "Pretix ticketing software";

  inputs = {
    # Some utility functions to make the flake less boilerplaty
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "nixpkgs/nixos-22.11";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlay ];
          };
        in
        {
          defaultPackage = pkgs.pretix;
          packages = { inherit (pkgs) pretix update-pretix pretixSdist nodeDeps; };
        }) // {

      overlay = final: prev: let
        pretixVersion = "4.16.0";
        pretixSource = final.fetchFromGitHub {
          owner = "pretix";
          repo = "pretix";
          rev = "v${pretixVersion}";
          hash = "sha256-xnlW8CbhYPAaO27nyH/ntP8pWYPaGPPyG2A2HGiv6Yo=";
        };
        pretixSdist = final.stdenv.mkDerivation {
          pname = "pretix-sdist";
          version = pretixVersion;
          src = pretixSource;

          buildInputs = with final; [
            python3
            python3Packages.setuptools
            python3Packages.setuptools-rust
          ];

          buildPhase = ''
            cd src
            python3 setup.py sdist -k
          '';
          installPhase = ''
            cp -r pretix-${pretixVersion}/ $out
          '';
        };
      in {
        inherit pretixSdist;
        update-pretix = final.writeShellApplication {
          name = "update-pretix";
          runtimeInputs = with final; ([
            poetry
            python3
            stdenv.cc
            node2nix
            gawk
          ] ++ (with python3Packages; [
            setuptools
          ]));
          text = ''
            set -euo pipefail
            set -x

            workdir=$(mktemp -d)
            #workdir="/tmp/tmp.Dc5402jTEp"
            trap 'rm -rf "$workdir"' EXIT

            pushd "$workdir"
            cp ${./pyproject.toml.template} pyproject.toml
            chmod +w pyproject.toml

            awk '{
              if ($0 ~ /\[dev\]/){output="off"; next}
              if ($0 !~ /\[\w+\]/ && (output == "on" || output == "") && $0 !~ /^$/){ print }
            }' ${pretixSdist}/pretix.egg-info/requires.txt | xargs poetry add

            poetry add gunicorn

            mkdir -p node-deps/
            cd node-deps
            npmSrc=${pretixSource}/src/pretix/static/npm_dir
            node2nix -i "''${npmSrc}/package.json" -l "''${npmSrc}/package-lock.json"

            popd
            cp "$workdir"/{pyproject.toml,poetry.lock} ./
            mv "$workdir"/node-deps ./node-deps
          '';
        };
        nodeDeps = ((final.callPackage ./node-deps {}).shell.override (old: {
          src = pretixSource + "/src/pretix/static/npm_dir/";
        })).nodeDependencies;
        #update-pretix = prev.writeScriptBin "update-pretix" ''
        #'';
        pretix = (prev.poetry2nix.mkPoetryApplication {
          projectDir = pretixSource;
          pyproject = ./pyproject.toml;
          poetrylock = ./poetry.lock;
          src = pretixSource + "/src";
          #python =
          #preferWheels = true;

          overrides = prev.poetry2nix.overrides.withDefaults (pself: psuper: let
            needsSetuptools = [
              #"django-phonenumber-field"
              "django-i18nfield"
              "pyuca"
              "defusedcsv"
              "click"
              "click-didyoumean"
              "slimit"
              "static3"
              "dj-static"
              "phonenumberslite"
              "vat-moss-forked"
              "django-hierarkey"
              "python-u2flib-server"
              "paypalhttp"
              "paypal-checkout-serversdk"
              "paypalcheckoutsdk"
              "django-jquery-js"
              "django-bootstrap3"
              "django-markup"
              "django-mysql"
              "django-localflavor"
              "django-formset-js-improved"
              "django-libsass"
              "drf-ujson2"
              "django-scopes"
            ];
            withSetuptools = pp: pp.overrideAttrs (a: {
              buildInputs = (a.buildInputs or [ ])
                ++ [ pself.setuptools pself.poetry ];
            });

            allWithSetuptools =  builtins.listToAttrs (map (name: {
              inherit name;
              value = withSetuptools psuper.${name};
            }) needsSetuptools );
          in ({
            inherit (final.python3Packages) cryptography typing-extensions pytz six pycparser asgiref sqlparse async-timeout #django-scopes
            ;
            # The tlds package is an ugly beast which fetches its content
            # at build-time. So instead replace it by a fixed hardcoded
            # version.
            tlds = withSetuptools (psuper.tlds.overrideAttrs (a: {
              src = final.fetchFromGitHub {
                owner = "regnat";
                repo = "tlds";
                rev = "3c1c0ce416e153a975d7bc753694cfb83242071e";
                sha256 = "sha256-u6ZbjgIVozaqgyVonBZBDMrIxIKOM58GDRcqvyaYY+8=";
              };
            }));
            # For some reason, tqdm is missing a dependency on toml
            # django-scopes = final.python3Packages.django-scopes.overrideAttrs (a: {
            #   # Django-scopes does something fishy to determine its version,
            #   # which breaks with Nix
            #   propagatedBuildInputs = #(a.propagatedBuildInputs or [ ]) ++
            #     [ pself.django ];
            #   #nativeCheckInputs =
            #   nativeCheckInputs = #(a.nativeCheckInputs or [ ]) ++
            #     [ pself.pytest-django pself.pytestCheckHook ];
            #   prePatch = (a.prePatch or "") + ''
            #     sed -i "s/version = '?'/version = '${a.version}'/" setup.py
            #   '';
            # });
            css-inline = psuper.css-inline.override {
              preferWheel = true;
            };
            django-hijack = final.python3Packages.django_hijack.overridePythonAttrs (a: {
              propagatedBuildInputs = with pself; [
                django
                django_compat
              ];
              checkInputs = [
                final.python3.pkgs.pytestCheckHook
                pself.pytest-django
              ];
            });

            #django-hijack = .override { preferWheels = true; };
            pypdf2 = psuper.pypdf2.overrideAttrs (a: {
              LC_ALL = "en_US.UTF-8";
              buildInputs = (a.buildInputs or [ ])
                ++ (with final.python3Packages; [
                  setuptools
                  flit-core
                  final.glibcLocales
                ]);
            });

            reportlab = psuper.reportlab.overrideAttrs (a: let
              ft = final.freetype.overrideAttrs (oldArgs: { dontDisableStatic = true; });
            in {
              LC_ALL = "en_US.UTF-8";
                postPatch = ''
                  substituteInPlace setup.py \
                    --replace "mif = findFile(d,'ft2build.h')" "mif = findFile('${final.lib.getDev ft}','ft2build.h')"
                  # Remove all the test files that require access to the internet to pass.
                  rm tests/test_lib_utils.py
                  rm tests/test_platypus_general.py
                  rm tests/test_platypus_images.py
                  # Remove the tests that require Vera fonts installed
                  rm tests/test_graphics_render.py
                  rm tests/test_graphics_charts.py
                '';
              buildInputs = (a.buildInputs or [ ])
                ++ (with pself; [
                  ft
                  setuptools
                  setuptools-scm
                  pillow
                ]);
            });

            # Currently only in nixpkgs-unstable...
            #django-phonenumber-field = prev.python3Packages.django-phonenumber-field;
            django-phonenumber-field = withSetuptools (psuper.django-phonenumber-field.overrideAttrs (o: rec {
                pname = "django-phonenumber-field";
                version = "7.0.2";
                format = "pyproject";
                buildInputs = (o.buildInputs or [ ])
                  ++ [ pself.setuptools-scm ];
                #buildInputs =
                #self.setuptools-scm

                src = final.fetchFromGitHub {
                  owner = "stefanfoulis";
                  repo = pname;
                  rev = "refs/tags/${version}";
                  hash = "sha256-y5eVyF6gBgkH+uQ2424kCe+XRB/ttbnJPkg6ToRxAmI=";
                };


                SETUPTOOLS_SCM_PRETEND_VERSION = version;
            }));

            django = psuper.django.overrideAttrs (a: {
              propagatedNativeBuildInputs = (a.propagatedNativeBuildInputs or []) ++ (with final; [
                gettext
              ]);
            });

            pretix = psuper.pretix.overrideAttrs (a: let
              bi = builtins.filter (d: d.pname == "python3.10-django") (a.buildInputs or []);
            in {
              buildInputs = bi ++ [
                final.nodePackages.npm
                final.python3Packages.mysqlclient
                final.gettext
                pself.django
              ];
              ignoreCollisions = true;
            });
          } // allWithSetuptools));
          propagatedNativeBuildInputs = [
            final.nodePackages.npm
            final.nodeDeps
          ];
          preBuild = ''
            mkdir -p pretix/static.dist/node_prefix/
            cp -r ${final.nodeDeps}/lib/node_modules ./pretix/static.dist/node_prefix/
            #stat /build/src/pretix/static.dist/node_prefix/node_modules/.package-lock.json
            chmod +w ./pretix/static.dist/node_prefix/node_modules/.package-lock.json
          '';
          prePatch = ''
            sed -i "/subprocess.check_call(\['npm', 'install'/d" setup.py
          '';
        }).dependencyEnv;
      };

      nixosModules.pretix = {
        imports = [ ./nixos-module.nix ];
        nixpkgs.overlays = [ self.overlay ];
      };

      nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.pretix
          ({ config, lib, pkgs, ... }:
            let
              # XXX: Should be passed out-of-band so as to not end-up in the
              # Nix store
              pretix_secret_cfg = pkgs.writeText "pretix-secrets"
                (lib.generators.toKeyValue { } {
                  PRETIX_DATABASE_PASSWORD = "foobar";
                });
            in
            {
              system.configurationRevision = self.rev or "dirty";

              services.pretix = {
                enable = true;
                config = {
                  pretix = {
                    instance_name = "Test pretix";
                  };
                  locale = {
                    default = "de";
                    timezone = "Europe/Berlin";
                  };

                  languages.enabled = "de,de_informal";
                  metrics = {
                    enabled = true;
                    user = "test";
                    passphrase = "test";
                  };
                  database = {
                    backend = "postgresql";
                    name = "pretix";
                    host = "localhost";
                    user = "pretix";
                  };
                };
                secretConfig = pretix_secret_cfg;
                host = "0.0.0.0";
                port = 8000;
              };

              # Ad-hoc initialisation of the database password.
              # Ideally the postgres host is on another machine and handled
              # separately
              systemd.services.pretix-setup = {
                script = ''
                  # Setup the db
                  set -eu

                  ${pkgs.utillinux}/bin/runuser -u ${config.services.postgresql.superUser} -- \
                    ${config.services.postgresql.package}/bin/psql -c \
                    "ALTER ROLE ${config.services.pretix.config.database.user} WITH PASSWORD '$PRETIX_DATABASE_PASSWORD'"
                '';

                after = [ "postgresql.service" ];
                requires = [ "postgresql.service" ];
                before = [ "pretix.service" ];
                requiredBy = [ "pretix.service" ];
                serviceConfig.EnvironmentFile = pretix_secret_cfg;
              };

              networking.firewall.allowedTCPPorts =
                [ config.services.pretix.port ];

              networking.hostName = "pretix";
              services.mingetty.autologinUser = "root";
            })
        ];
      };
    };
}
