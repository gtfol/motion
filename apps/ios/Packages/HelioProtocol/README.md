# Helio Bluetooth protocol

Vendored subset of OpenCircuit's ZeppKit from MIT-licensed commit
`2d07e550fbabba61990024e254f8b9654d50bd0a` (before its license change):
https://github.com/perezjuanj/OpenCircuit/tree/2d07e550fbabba61990024e254f8b9654d50bd0a

Copyright 2026 Juan Perez. See LICENSE. B163.swift retains its tiny-ECDH-c
public-domain attribution. No source from later noncommercial releases is used.
Only authentication, framing, history decoding and session primitives are included;
the fake strap and its synthetic fixtures are test-only. Motion always uses the
keep-on-device acknowledgement and never deletes band history.

Motion's local adaptations distinguish zero-stage sleep records from malformed
stage tables and let callers skip an unusable type while retaining its history on
the strap and continuing the other requested types.

Sleep stage end minutes are inclusive: equal start/end records one minute.
The raw fields remain unchanged; `Stage.endExclusive` provides the following
minute boundary, and gap detection uses it. This independent adaptation follows
the hardware observations in [OpenCircuit issue 312](https://github.com/perezjuanj/OpenCircuit/issues/312),
corroborated by Motion's reported zero-duration stage inside a valid session.
No implementation from a later OpenCircuit release was copied.

Run tests on macOS: `swift test --scratch-path /private/tmp/motion-helio-protocol-tests`.
