---
title: puppet-format
section: 1
header: User Commands
footer: puppet-format
---

# NAME

**puppet-format** - format Puppet manifests with predictable, lexer-aware source transformations

# SYNOPSIS

**puppet-format** [*OPTIONS*] *FILE*...

**puppet-format** [*OPTIONS*] *DIRECTORY*...

# DESCRIPTION

**puppet-format** is a Puppet manifest formatter focused on predictable
indentation and lexer-aware source transformations.

It is intended for Puppet 8 code, uses 4-space indentation by default, and
uses `puppet-lint` lexer tokens instead of regular-expression parsing wherever
practical.

The formatter handles resource declarations, multiline arrays, hash rockets,
assignments, comments, conditional blocks, and Puppet relationship operators
while protecting multiline strings and heredocs from unsafe rewrites.

When a directory is specified, Puppet files below that directory are
formatted.

# OPTIONS

**--indent-width** *N*
: Set the number of spaces used for one indentation level. The normal default
  is 4.

**--[no-]normalize-rockets**
: Enable or disable normalization of whitespace around Puppet hash rockets
  (`=>`).

**--[no-]align-rockets-sequential**
: Enable or disable alignment of `=>` operators across sequential
  hash/resource parameter lines.

**--[no-]align-rockets-by-indent**
: Enable or disable broader `=>` alignment for entries at the same structural
  indentation level.

**--[no-]align-rockets-oneline**
: Control whether one-line hash expressions participate in hash-rocket
  alignment.

**--[no-]normalize-assignments**
: Enable or disable whitespace normalization around ordinary variable
  assignment (`=`).

**--[no-]align-assignments-sequential**
: Enable or disable alignment of consecutive variable assignments.

**--[no-]split-empty-resource-body**
: Control formatting of empty resource bodies. In split mode, an empty
  resource terminator may be placed on its own resource-parameter line.

**--[no-]normalize-relationships**
: Enable or disable layout normalization for Puppet relationship operators
  `->` and `~>`.

**--[no-]indent-reference-relationships**
: Enable or disable additional indentation for relationship continuation lines
  between resource references.

**--[no-]align-comments**
: Enable or disable indentation rewriting for standalone comment lines. With
  `--no-align-comments`, their original leading indentation is preserved.

**--[no-]align-array-elements**
: Enable or disable normalization of elements in multiline arrays. When
  enabled, top-level elements are placed on separate lines and indented one
  structural level inside the array.

**--check**
: Check whether formatting changes are required instead of silently accepting
  formatting differences. This is useful in CI.

**--diff**
: Show a unified diff between the original and formatted Puppet source. It is
  commonly used together with `--check`.

# CONDITIONAL FORMATTING

Conditional block normalization is part of the normal structural formatting
pass.

Puppet `if`, `elsif`, and `else` blocks are normalized to the common form:

```puppet
if $condition {
    ...
} elsif $other_condition {
    ...
} else {
    ...
}
```

For example:

```puppet
if $a {} elsif $b {} else {}
```

is formatted as:

```puppet
if $a {
} elsif $b {
} else {
}
```

A separate `else` or `elsif` line following a closing brace is normalized so
that the continuation keyword follows the brace on the same line:

```puppet
if $enabled {
    notice('enabled')
} else {
    notice('disabled')
}
```

# RESOURCE DECLARATIONS

Resource titles are moved to their own line and resource parameters are
indented one level below the title.

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

Only top-level resource parameter separators are split. Commas inside nested
calls, arrays, and hashes are not treated as resource parameter boundaries.

Resource-style class declarations are also recognized:

```puppet
class {
    'example':
        parameter => 'value';
}
```

# ARRAY ELEMENT ALIGNMENT

With **--align-array-elements**, already-multiline arrays are normalized so
that their opening bracket, top-level elements, and closing bracket have
predictable indentation.

Input:

```puppet
$packages = [ 'one',
              'two',
              'three' ]
```

Output:

```puppet
$packages = [
    'one',
    'two',
    'three'
]
```

Compact one-line arrays remain compact unless another formatting rule changes
them:

```puppet
$values = ['one', 'two', 'three']
```

Only top-level commas are treated as array-element separators. Commas inside
nested function calls, hashes, or nested arrays are not split at the outer
array level.

For example:

```puppet
$values = [
    template($a, $b),
    { 'one' => 1, 'two' => 2 },
    ['nested-a', 'nested-b'],
]
```

The formatter changes array layout and indentation but does not add or remove
element commas. Existing trailing commas are preserved.

## Array resource titles

Arrays can be used as resource titles.

Input:

```puppet
package {
    [ "docker-compose-multiversion-1.29.2",
      "docker-compose-multiversion-1.29.2-cli",
      "docker-compose-multiversion-1.29.2-plugin" ]:
            ensure => absent,
}
```

With array-element alignment enabled:

```puppet
package {
    [
        "docker-compose-multiversion-1.29.2",
        "docker-compose-multiversion-1.29.2-cli",
        "docker-compose-multiversion-1.29.2-plugin"
    ]:
        ensure => absent,
}
```

The resource parameters and comments belonging to them are indented at the
same level as the array elements. The `]:` line remains at resource-title
depth.

# RESOURCE RELATIONSHIPS

Puppet relationship operators are handled independently from hash rockets.

The supported relationship operators are:

```text
->
~>
```

They are never treated as `=>`.

With relationship normalization enabled:

```puppet
file {
    '/tmp/example':
        ensure => file;
} -> service {
    'example':
        ensure => running;
}
```

is formatted as:

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

The same rule applies to notification relationships using `~>`.

Several whitespace variants are normalized consistently. For example:

```puppet
}->file {
```

or:

```puppet
}
->
file {
```

become:

```puppet
}
-> file {
```

Relationship normalization is token-based and does not intentionally move an
operator across comments.

## Resource-reference relationships

Resource-reference chains can receive additional continuation indentation.

For example:

```puppet
Class['example'] -> File['/tmp/example'] ~> Exec['reload']
```

can be formatted as:

```puppet
Class['example']
    -> File['/tmp/example']
    ~> Exec['reload']
```

Use **--no-indent-reference-relationships** to disable that additional
indentation.

# HASH ROCKETS

With hash-rocket normalization enabled, irregular whitespace around `=>` is
normalized.

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

Sequential alignment can then produce:

```puppet
file {
    '/tmp/example':
        ensure => file,
        mode   => '0644',
        owner  => 'root',
}
```

Normalization and alignment are separate operations.

# VARIABLE ASSIGNMENTS

Assignment formatting applies to ordinary variable assignment (`=`), not hash
rockets or comparison operators.

Input:

```puppet
$template_name=$title
$index_prefix =regsubst($index_pattern, '-?\*.*$', '')
```

With assignment normalization:

```puppet
$template_name = $title
$index_prefix = regsubst($index_pattern, '-?\*.*$', '')
```

Sequential assignment alignment can produce:

```puppet
$minute      = undef
$hour        = undef
$destination = 'nfs'
```

# COMMENTS

Standalone comment indentation can be controlled independently from ordinary
source indentation.

With:

```text
--no-align-comments
```

the formatter preserves the original leading indentation of standalone comment
lines instead of passing them through the indentation rewrite.

Trailing-whitespace cleanup is separate from comment indentation, so trailing
spaces may still be removed.

# MULTILINE STRINGS AND HEREDOCS

The formatter protects multiline strings and heredoc content from structural
indentation and trailing-whitespace transformations where whitespace may be
semantically significant.

For example:

```puppet
$value = 'line one
line two
line three
'
```

The physical lines inside the string are not arbitrarily re-indented.

Interpolated multiline double-quoted strings are also protected using lexer
token information.

# UTF-8

Source edits use byte offsets rather than Ruby character indexes so that
multibyte UTF-8 content before an edited token does not corrupt token
positions.

# EXAMPLES

Format a manifest in place:

```sh
puppet-format manifest.pp
```

Format Puppet files below a directory:

```sh
puppet-format .
```

Check a directory for formatting differences:

```sh
puppet-format --check .
```

Show formatting differences in CI:

```sh
puppet-format --check --diff manifests/
```

Disable multiline-array normalization:

```sh
puppet-format --no-align-array-elements manifest.pp
```

Disable relationship normalization:

```sh
puppet-format --no-normalize-relationships manifest.pp
```

Preserve standalone comment indentation:

```sh
puppet-format --no-align-comments manifest.pp
```

# REQUIREMENTS

**puppet-format** is intended for:

- Ruby 3.x
- Puppet 8
- `puppet-lint` 5.x

The dependency loader prefers libraries available to the system Ruby. If a
required dependency cannot be loaded normally, Puppet Labs library and gem
paths under `/opt/puppetlabs/puppet` may be used as fallback paths while the
formatter continues running under the system Ruby.

System Ruby paths retain priority over Puppet Labs fallback paths.

# LICENSE

**puppet-format** is distributed under the BSD 2-Clause License.

See `LICENSE` for the full license text.
