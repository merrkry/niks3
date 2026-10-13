{ pkgs, niks3-hook }:
let
  inherit (pkgs) lib;
  base = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../nixosModules/niks3-auto-upload.nix
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        services.niks3-auto-upload = {
          enable = lib.mkDefault true;
          package = niks3-hook;
          serverUrl = "https://cache.example.com";
        };
      }
    ];
  };
  evaluate =
    options: (base.extendModules { modules = [ { services.niks3-auto-upload = options; } ]; }).config;
  failures = config: map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
  execStart = config: config.systemd.services.niks3-auto-upload.serviceConfig.ExecStart;
  tokenFile = "/run/secrets/niks3 token";
  tokenScript = ''/run/token-command --audience "cache with spaces" '$TOKEN' '%n' '';
  fileConfig = evaluate { authTokenFile = tokenFile; };
  scriptConfig = evaluate { authTokenScript = tokenScript; };
  mtls = {
    enable = true;
    clientCert = "/run/secrets/client.crt";
    clientKey = "/run/secrets/client.key";
    caCert = "/run/secrets/ca.crt";
  };
  mtlsConfig = evaluate { inherit mtls; };
  noBearerFlags = config: !lib.hasInfix "--auth-token-" (execStart config);
  mutualExclusion = "services.niks3-auto-upload.authTokenFile and authTokenScript are mutually exclusive";
  tests = lib.runTests {
    testTokenFile = {
      expr =
        failures fileConfig == [ ]
        && lib.hasInfix ''"--auth-token-path" "/run/secrets/niks3 token"'' (execStart fileConfig)
        && !lib.hasInfix "--auth-token-script" (execStart fileConfig);
      expected = true;
    };
    testTokenScriptQuoting = {
      expr =
        failures scriptConfig == [ ]
        && lib.hasInfix ''"--auth-token-script" "/run/token-command --audience \"cache with spaces\" '$$TOKEN' '%%n' "'' (
          execStart scriptConfig
        )
        && !lib.hasInfix "--auth-token-path" (execStart scriptConfig);
      expected = true;
    };
    testMutualExclusion = {
      expr = failures (evaluate {
        authTokenFile = tokenFile;
        authTokenScript = tokenScript;
      });
      expected = [ mutualExclusion ];
    };
    testMissingAuthentication = {
      expr = failures (evaluate { });
      expected = [ "services.niks3-auto-upload requires authTokenFile, authTokenScript, or mtls.enable" ];
    };
    testMTLSWithoutBearer = {
      expr =
        failures mtlsConfig == [ ]
        && noBearerFlags mtlsConfig
        && lib.hasInfix ''"--client-cert" "/run/secrets/client.crt"'' (execStart mtlsConfig)
        && lib.hasInfix ''"--client-key" "/run/secrets/client.key"'' (execStart mtlsConfig)
        && lib.hasInfix ''"--ca-cert" "/run/secrets/ca.crt"'' (execStart mtlsConfig);
      expected = true;
    };
    testLegacyMTLSEmptyTokenFile = {
      expr =
        let
          config = evaluate {
            inherit mtls;
            authTokenFile = "";
          };
        in
        failures config == [ ] && noBearerFlags config;
      expected = true;
    };
    testMTLSWithBearer = {
      expr = failures (evaluate {
        inherit mtls;
        authTokenScript = tokenScript;
      });
      expected = [ ];
    };
    testMTLSWithBothBearerSources = {
      expr = failures (evaluate {
        inherit mtls;
        authTokenFile = tokenFile;
        authTokenScript = tokenScript;
      });
      expected = [ mutualExclusion ];
    };
    testDisabled = {
      expr =
        let
          config = evaluate { enable = false; };
        in
        failures config == [ ] && !(config.systemd.services ? niks3-auto-upload);
      expected = true;
    };
  };
in
assert lib.assertMsg (tests == [ ]) (builtins.toJSON tests);
pkgs.runCommand "nixos-auto-upload-module" { } ''
  touch $out
''
