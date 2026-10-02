# examples/ — the source of truth for docs code samples

Mirrors `wefunder-node/examples/README.md` (the cross-language contract). Each file is a real,
loadable module exposing `example(wf)`. A `# region <key>` … `# endregion` block marks the snippet
shown on docs.wefunder.com; everything outside it is harness. `<key>` is an `operationId`
(auto-binds to that operation's Ruby tab) or `guides/<name>`.

```
ruby script/build_examples_manifest.rb   # → examples_manifest.json (lang "Ruby")
bundle exec rspec spec/examples_spec.rb  # load + coverage + freshness + shape gates
```

Every public `operationId` in `openapi/openapi.yaml` must have an example here or be listed in
`coverage-allowlist.json` (curl-only). Files starting with `_` are hidden harness.
