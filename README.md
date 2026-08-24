# puppet-format

`puppet-format` is a Puppet manifest formatter focused on predictable indentation and lexer-aware source transformations.

The formatter is intended for Puppet 8 code, uses 4-space indentation by default, and relies on `puppet-lint` lexer tokens instead of regular-expression parsing wherever practical.

It formats resource declarations, hash rockets, assignments, comments, conditional blocks, and Puppet relationship operators while protecting multiline strings and heredocs from unsafe rewrites.

## Features

- 4-space structural indentation by default
- Resource titles are moved to their own line
- Resource parameters are indented one level below resource titles
- Supports normal resources, defined resources, and resource-style `class { ... }` declarations
- Normalizes `if` / `elsif` / `else` block layout
- Keeps `elsif` and `else` on the same line as the preceding closing brace
- Normalizes Puppet relationship operators `->` and `~>`
- Optional indentation of relationship lines targeting resource references
- Optional hash-rocket (`=>`) normalization and alignment
- Optional variable-assignment (`=`) normalization and alignment
- Optional comment indentation control
- Configurable handling of empty resource bodies
- Preserves heredocs and multiline quoted strings
- Removes trailing whitespace outside protected multiline content
- UTF-8-safe byte-offset source editing
- Validates Puppet syntax before and after formatting
- `--check` and `--diff` modes for CI and code review

## Requirements

- Ruby 3.x
- Puppet 8
- `puppet-lint` 5.x

The dependency loader is designed to prefer libraries available to the system Ruby. If a required dependency cannot be loaded normally, Puppet Labs paths under `/opt/puppetlabs/puppet` can be added as fallback paths while the formatter continues to run under the system Ruby.

System Ruby paths retain priority over fallback paths.

## Usage

Format a file in place:

```bash
puppet-format manifest.pp
```

Format all Puppet files below a directory:

```bash
puppet-format .
```

Check whether files require formatting:

```bash
puppet-format --check .
```

Show a unified diff without modifying files:

```bash
puppet-format --check --diff .
```

A useful CI invocation is:

```bash
puppet-format --check --diff manifests/
```

## Main options

The exact defaults are defined by the command-line wrapper, but the formatter supports the following formatting controls:

```text
--indent-width N

--[no-]normalize-rockets
--[no-]align-rockets-sequential
--[no-]align-rockets-by-indent
--[no-]align-rockets-oneline

--[no-]normalize-assignments
--[no-]align-assignments-sequential

--[no-]split-empty-resource-body

--[no-]normalize-relationships
--[no-]indent-reference-relationships

--[no-]align-comments

--check
--diff
```

Conditional block normalization is part of the normal structural formatting pass and does not require a separate option.

---

# Conditional formatting

Puppet uses `elsif`, not `elif`.

The formatter normalizes conditional blocks to the common Puppet layout:

```puppet
if $condition {
    ...
} elsif $other_condition {
    ...
} else {
    ...
}
```

## Empty conditional blocks

Input:

```puppet
if $a {} elsif $b {} else {}
```

Output:

```puppet
if $a {
} elsif $b {
} else {
}
```

The opening and closing braces of an empty conditional body are therefore placed on separate lines.

## `else` placement

Input:

```puppet
if $enabled {
    notice('enabled')
}
else {
    notice('disabled')
}
```

Output:

```puppet
if $enabled {
    notice('enabled')
} else {
    notice('disabled')
}
```

Likewise:

```puppet
}
elsif $condition {
```

is normalized to:

```puppet
} elsif $condition {
```

## One-line conditional bodies

Input:

```puppet
if $a { notice('a') } elsif $b { notice('b') } else { notice('c') }
```

Output:

```puppet
if $a {
    notice('a')
} elsif $b {
    notice('b')
} else {
    notice('c')
}
```

Conditional layout is lexer-driven. The formatter identifies Puppet conditional tokens and brace structure instead of parsing `if`, `elsif`, and `else` with raw regular expressions.

---

# Resource relationships

Puppet relationship operators are handled separately from hash rockets:

```text
->
~>
```

They are never treated as `=>`.

## Relationship normalization

With relationship normalization enabled, the relationship operator starts a continuation line and the target follows the operator on the same line.

Input:

```puppet
file {
    '/tmp/example':
        ensure => file;
} -> service {
    'example':
        ensure => running;
}
```

Output:

```puppet
file {
    '/tmp/example':
        ensure => file;
}
-> service {
    'example':
        ensure => running;
}
```

The same rule applies to notification relationships:

```puppet
file {
    '/etc/example.conf':
        ensure => file;
}
~> service {
    'example':
        ensure => running;
}
```

These variants are normalized consistently:

```puppet
}->file {
```

```puppet
} ->
file {
```

```puppet
}
->
file {
```

into:

```puppet
}
-> file {
```

Use:

```bash
puppet-format --no-normalize-relationships manifest.pp
```

to disable relationship layout normalization.

## Resource-reference relationships

The formatter recognizes resource references through lexer token types, for example:

```puppet
Class['example']
File['/tmp/example']
Exec['reload']
```

With reference-relationship indentation enabled:

```puppet
Class['example'] -> File['/tmp/example'] ~> Exec['reload']
```

is formatted as:

```puppet
Class['example']
    -> File['/tmp/example']
    ~> Exec['reload']
```

Disable the additional indentation with:

```bash
puppet-format --no-indent-reference-relationships manifest.pp
```

Relationship normalization is token-based and does not intentionally move an operator across comments. Comments act as layout boundaries.

---

# Resource declaration formatting

Resource layout is normalized independently of hash-rocket alignment.

## Resource title

Input:

```puppet
file { $payload_dir:
    ensure => directory,
}
```

Output:

```puppet
file {
    $payload_dir:
        ensure => directory,
}
```

## Inline resource parameters

Input:

```puppet
file { $payload_file: ensure => file, mode => '0640', owner => 'root', }
```

Output:

```puppet
file {
    $payload_file:
        ensure => file,
        mode   => '0640',
        owner  => 'root',
}
```

Only top-level resource parameter separators are split. Commas inside nested calls, arrays, and hashes are not treated as resource parameter boundaries.

For example:

```puppet
file {
    '/tmp/example':
        content => template($a, $b),
        options => ['one', 'two'],
}
```

## Resource-style class declarations

The formatter recognizes resource-style class declarations:

```puppet
class {
    'example':
        parameter => 'value';
}
```

This is distinct from a normal class definition:

```puppet
class example {
    ...
}
```

---

# Hash rockets

## Normalization

With `--normalize-rockets`, irregular spacing around `=>` is normalized.

Input:

```puppet
{
    'user'      =>    'root',
    'mode'=> '0644',
}
```

Output without alignment padding:

```puppet
{
    'user' => 'root',
    'mode' => '0644',
}
```

## Sequential alignment

Input:

```puppet
file {
    '/tmp/example':
        ensure => file,
        mode => '0644',
        owner => 'root',
}
```

With sequential rocket alignment:

```puppet
file {
    '/tmp/example':
        ensure => file,
        mode   => '0644',
        owner  => 'root',
}
```

Normalization and alignment are separate operations: normalization removes irregular spacing first, and alignment can then add only the padding needed for visual alignment.

---

# Variable assignments

Assignment formatting is lexer-driven and applies to ordinary variable assignment (`=`), not hash rockets or comparison operators.

Input:

```puppet
$template_name=$title
$index_prefix =regsubst($index_pattern, '-?\\*.*$', '')
```

With assignment normalization:

```puppet
$template_name = $title
$index_prefix = regsubst($index_pattern, '-?\\*.*$', '')
```

Sequential assignment alignment can produce:

```puppet
$minute      = undef
$hour        = undef
$destination = 'nfs'
```

---

# Comments

Standalone comment indentation can be controlled independently from normal source indentation.

For example:

```bash
puppet-format --no-align-comments manifest.pp
```

preserves the original leading indentation of standalone comment lines instead of passing them through the indentation rewrite.

This is useful when comments have intentionally chosen visual positioning.

Trailing-whitespace cleanup is separate from comment indentation, so trailing spaces may still be removed from an otherwise preserved comment line.

---

# Empty resource bodies

The formatter can normalize empty resource bodies consistently.

Compact form:

```puppet
class {
    'example':;
}
```

Split form:

```puppet
class {
    'example':
        ;
}
```

The behavior is controlled by:

```text
--[no-]split-empty-resource-body
```

---

# Multiline strings and heredocs

The formatter protects multiline strings and heredoc content from structural indentation and trailing-whitespace transformations where whitespace may be semantically significant.

Example:

```puppet
$value = 'line one
line two
line three
'
```

The physical lines inside the string are not arbitrarily re-indented.

Interpolated multiline double-quoted strings are also protected using lexer token information.

---

# UTF-8 safety

Source edits use byte offsets rather than Ruby character indexes.

This matters when manifests contain multibyte UTF-8 text before a token being edited, for example:

```puppet
String $script_path, # скрипт для выполнения API call
```

The formatter applies offset-based edits to a binary copy of the source and restores the original encoding afterward.

---

# Formatting pipeline

The formatter uses staged transformations so token line and column information always corresponds to the current source text.

A simplified pipeline is:

1. Validate the original Puppet source.
2. Lex the source with `puppet-lint`.
3. Normalize resource layout.
4. Re-lex.
5. Normalize `if` / `elsif` / `else` layout.
6. Re-lex.
7. Normalize `->` / `~>` relationship layout, if enabled.
8. Re-lex.
9. Calculate structural, resource, comment, protected-line, and relationship metadata.
10. Rewrite indentation.
11. Normalize and/or align hash rockets, if enabled.
12. Normalize and/or align assignments, if enabled.
13. Re-lex the final result.
14. Remove trailing whitespace outside protected multiline content.
15. Validate the formatted Puppet source.

Re-lexing after transformations that change physical line breaks is important because lexer `line` and `column` positions must match the current source.

---

# CI example

A typical CI check is:

```bash
puppet-format --check --diff .
```

Useful additional validation:

```bash
git diff --check
```

To inspect invisible whitespace:

```bash
sed -n '1,160p' manifest.pp | cat -A
```

---

# Design goals

`puppet-format` intentionally keeps formatting concerns separate:

- structural indentation
- conditional layout
- resource layout
- relationship normalization
- hash-rocket normalization
- hash-rocket alignment
- assignment normalization
- assignment alignment
- comment indentation
- protected multiline content
- trailing-whitespace cleanup

The implementation prefers lexer-aware transformations over direct regular-expression parsing wherever possible. This reduces the risk of misinterpreting braces, commas, operators, comments, interpolation, or strings inside nested Puppet expressions.

---

# License

`puppet-format` is distributed under the BSD 2-Clause License.

See `LICENSE` for the full license text.

SPDX-License-Identifier: BSD-2-Clause
