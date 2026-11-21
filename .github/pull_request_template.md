# What changed

<!-- One skill per PR. Name it, and say which evidence channel changed. -->

Skill:
Channel / tool:
Why:

## Evidence

<!-- Paste the commands you ran and their real output. Numbers, not adjectives. -->

```text
bash skills/SKILL/references/selftest.sh
bash verify.sh
```

## Checklist

- [ ] The self-test for the touched skill was run and passes
      (the touched skill's `references/selftest.sh`).
- [ ] `bash verify.sh` is green (or every `SKIP` is explained in this PR).
- [ ] No machine-specific absolute paths (`/Users/…`, `/home/…`, an assumed `$HOME`)
      in files, docs or scripts; paths are repo- or skill-relative.
- [ ] `SKILL.md` frontmatter is valid YAML: `name` equals the directory name, and
      `description` is a single valid scalar (no colon-space inside a plain scalar).
- [ ] Every command in the docs was actually run and its output reproduced.
- [ ] Docs updated in the same PR if a flag, output field or dependency changed.

## Related issues

<!-- Closes #0 -->
