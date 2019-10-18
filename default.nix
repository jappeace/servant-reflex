{ mkDerivation, base, bytestring, case-insensitive, containers
, data-default, exceptions, generic-lens, ghcjs-dom, http-api-data
, http-media, jsaddle, lens, mtl, network-uri, reflex
, reflex-dom-core, safe, servant, servant-auth, servant-client-core
, stdenv, string-conversions, text, transformers
}:
mkDerivation {
  pname = "servant-reflex";
  version = "0.3.4";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    base bytestring case-insensitive containers data-default exceptions
    generic-lens ghcjs-dom http-api-data http-media jsaddle lens mtl
    network-uri reflex reflex-dom-core safe servant servant-auth
    servant-client-core string-conversions text transformers
  ];
  description = "servant API generator for reflex apps";
  license = stdenv.lib.licenses.bsd3;
}
