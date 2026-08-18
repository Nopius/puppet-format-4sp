# puppet-format-4sp

`puppet-format-4sp` is a Puppet manifest formatter focused on predictable **4-space indentation**, resource layout normalization, hash-rocket alignment, assignment alignment, and safe handling of multiline strings and heredocs.

It is intended for Puppet 8 code and uses `puppet-lint`'s lexer to avoid formatting inside quoted multiline content.

## Features

- 4-space structural indentation by default
- Resource titles are moved to their own line
- Resource parameters are indented one level below the resource title
- Supports normal resources, defined resources, and resource-like `class { ... }` declarations
- Optional hash-rocket normalization and alignment
- Optional assignment normalization and alignment
- Optional handling of empty resource bodies (`title:;`)
- Preserves heredocs and multiline quoted strings
- Preserves resource relationship operators such as `->` and `~>`
- Removes trailing whitespace outside protected multiline content
- Validates Puppet syntax before and after formatting
- `--check` and `--diff` modes for CI and code review

---

## Example

Input:

```puppet
file { $payload_file: ensure  => file,
             mode    => '0640', owner => 'root',
             group   => 'root',
             content => to_json_pretty($payload),
             require => File[$payload_dir],
}
```

Formatted:

```puppet
file {
    $payload_file:
        ensure  => file,
        mode    => '0640',
        owner   => 'root',
        group   => 'root',
        content => to_json_pretty($payload),
        require => File[$payload_dir],
}
```

---

## Requirements

Typical environment:

- Puppet 8
- Ruby 3
- `puppet-lint` 5.x

If Puppet is installed from Puppet Labs packages, using Puppet's embedded Ruby is recommended:

```bash
#!/opt/puppetlabs/puppet/bin/ruby
```

If `puppet-lint` is installed in a separate gem tree, its `lib` directory can be added explicitly:

```ruby
$LOAD_PATH.unshift('/usr/local/share/gems/gems/puppet-lint-5.1.1/lib')

require 'puppet'
require 'puppet-lint'
```

This avoids exposing an entire gem tree built for a different Ruby ABI.

If you don't have Puppet Labs server installed, then use Ruby gem installation for both required modules:

```bash
gem install puppet
gem install puppet-lint
```
 
and use appropriate path for system-wide ruby (not embedded):

```bash
#!/usr/bin/ruby
```

---

## Usage

Format a file:

```bash
puppet-format-4sp manifest.pp
```

Check whether formatting changes are required:

```bash
puppet-format-4sp --check manifest.pp
```

Show the proposed changes:

```bash
puppet-format-4sp --check --diff manifest.pp
```

A common CI invocation is:

```bash
puppet-format-4sp --check --diff manifests/*.pp
```

---

# Options

## `--check`

Do not silently accept formatting differences. Use this mode in CI or pre-commit checks.

Example:

```bash
puppet-format-4sp --check manifest.pp
```

If the file requires formatting, the command reports it instead of treating the file as already formatted.

---

## `--diff`

Show a unified diff between the original and formatted Puppet source.

Example:

```bash
puppet-format-4sp --check --diff manifest.pp
```

Example output:

```diff
-    file { $payload_dir:
+    file {
+        $payload_dir:
             ensure => directory,
```

---

## `--indent-width N`

Controls the number of spaces used for one indentation level.

Default:

```text
4
```

Example:

```bash
puppet-format-4sp --indent-width 4 manifest.pp
```

Input:

```puppet
class example {
  if $enabled {
    notify { 'enabled': }
  }
}
```

With `--indent-width 4`:

```puppet
class example {
    if $enabled {
        notify {
            'enabled':
        }
    }
}
```

---

## `--[no-]normalize-rockets`

Controls spacing around Puppet hash rockets (`=>`).

Default:

```text
enabled
```

### Enabled

Input:

```puppet
{
    'user'      =>    'root',
    'mode'=> '0644',
}
```

Output:

```puppet
{
    'user' => 'root',
    'mode' => '0644',
}
```

Normalization happens before alignment, so a later alignment option may intentionally add padding again.

### Disabled

```bash
puppet-format-4sp --no-normalize-rockets manifest.pp
```

Existing spaces around `=>` are preserved unless another enabled formatting pass changes them.

---

## `--[no-]align-rockets-sequential`

Aligns `=>` for sequential hash/resource parameter lines.

Example input:

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

Disable with:

```bash
puppet-format-4sp --no-align-rockets-sequential manifest.pp
```

Normalization and alignment are separate operations. With both enabled, normalization first removes irregular spacing and alignment then adds only the spacing required for alignment.

---

## `--[no-]align-rockets-by-indent`

Aligns hash rockets more broadly by structural block and indentation level.

This can align entries that are not necessarily directly adjacent, as long as they belong to the same enclosing structural block and have the same indentation.

Example:

```puppet
$settings = $flag ? {
    true => 1,
    "very_long_flag_value" => { 
        "option 1" => true,
        "very long option name" => false,
    },
    default => 0
}
```

Without alignment:

```puppet
$settings = $flag ? {
    true                   => 1,
    "very_long_flag_value" => {
        "option 1"              => true,
        "very long option name" => false,
    },
    default => 0
```

With alignment (default => is indented to the same level, even if not sequential):

```puppet
$settings = $flag ? {
    true                   => 1,
    "very_long_flag_value" => {
        "option 1"              => true,
        "very long option name" => false,
    },
    default                => 0
}
```

Disable with:

```bash
puppet-format-4sp --no-align-rockets-by-indent manifest.pp
```

Use this when you want broader visual alignment than `--align-rockets-sequential`.

---

## `--[no-]align-rockets-oneline`

Controls whether complete one-line `{ ... => ... }` expressions are eligible for rocket alignment.

Default:

```text
disabled
```

Example one-line hash:

```puppet
$template => { 'settings' => {}, 'aliases' => {} }
```

With the default setting, the formatter does not use this one-line hash as an alignment candidate.

Enable with:

```bash
puppet-format-4sp --align-rockets-oneline manifest.pp
```

Important: `--no-align-rockets-oneline` affects **alignment**, not basic rocket normalization. `--normalize-rockets` may still normalize spaces inside a one-line hash.

---

## `--[no-]normalize-assignments`

Normalizes spaces around plain variable assignment (`=`).

Example input:

```puppet
$template_name=$title
$index_prefix =regsubst($index_pattern, '-?\*.*$', '')
```

With assignment normalization:

```puppet
$template_name = $title
$index_prefix = regsubst($index_pattern, '-?\*.*$', '')
```

Enable with:

```bash
puppet-format-4sp --normalize-assignments manifest.pp
```

This applies to ordinary assignments, not hash rockets (`=>`) or comparison operators.

---

## `--[no-]align-assignments-sequential`

Aligns consecutive variable assignments.

Example input:

```puppet
$minute = undef
$hour = undef
$destination = 'nfs'
```

With assignment alignment:

```puppet
$minute      = undef
$hour        = undef
$destination = 'nfs'
```

Disable with:

```bash
puppet-format-4sp --no-align-assignments-sequential manifest.pp
```

If you do not want parameter/variable declarations visually padded to the longest variable name, keep this disabled.

---

## `--[no-]split-empty-resource-body`

Controls how an empty resource body is written.

This option makes these two inputs behave consistently:

```puppet
class {
    'opensearch::templates':;
}
```

and:

```puppet
class {
    'opensearch::templates': ;
}
```

### Split mode

With splitting enabled:

```puppet
class {
    'opensearch::templates':
        ;
}
```

### Compact mode

With splitting disabled:

```puppet
class {
    'opensearch::templates':;
}
```

The formatter distinguishes this from a resource that has actual parameters:

```puppet
file {
    '/tmp/example':
        ensure => file;
}
```

For a title followed by `;` on the next line, the terminator is kept at resource-parameter depth:

```puppet
class {
    'opensearch::policies':
        ;
}
```

---

# Resource declaration formatting

Resource layout is normalized independently of rocket alignment.

## Inline resource title

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

The resource title is always moved to the line after the opening brace.

---

## Inline resource parameters

Input:

```puppet
file { $payload_file: ensure => file, mode => '0640', owner => 'root',
}
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

Only top-level resource parameter separators are split. Commas inside nested expressions are not treated as resource parameter separators.

For example:

```puppet
file {
    '/tmp/example':
        content => template($a, $b),
        options => ['one', 'two'],
}
```

The commas inside `template(...)` and `[...]` are not mistaken for resource parameter boundaries.

---

## Resource-like `class { ... }`

The formatter recognizes resource-style class declarations:

```puppet
class {
    'zabbix_monitoring::opensearch':
        server_host => 'localhost';
}
```

This is different from a normal class definition:

```puppet
class example {
    ...
}
```

The former receives resource-title/resource-parameter indentation; the latter is treated as ordinary Puppet structure.

---

## Namespaced defined resources

Namespaced resource types are also recognized:

```puppet
opensearch::indexes::rollover_bootstrap {
    $alias:
        index_prefix => $index_prefix;
}
```

---

# Arrays and hashes

Current formatting preserves already-multiline array/hash layout unless a dedicated collection-layout option is implemented/enabled.

For example:

```puppet
discovery_nodes => [
    'node1',
    'node2',
    'node3',
],
```

is structurally indented, but its elements are not arbitrarily collapsed into one line.

## Planned collection-layout modes

A useful future interface is:

```text
--array-layout preserve|compact|split
--hash-layout preserve|compact|split
```

Recommended defaults:

```text
array-layout = preserve
hash-layout  = preserve
```

Suggested semantics:

### `preserve`

Keep existing collection line breaks.

```puppet
$array = [one, two,
    three,
]
```

remains structurally equivalent, apart from normal indentation/spacing passes.

### `compact`

Normalize the collection toward compact one-line form when it is safe to do so.

Example:

```puppet
$array = [ one,   two, three ]
```

becomes:

```puppet
$array = [one, two, three]
```

### `split`

Put every top-level collection entry on its own line.

Example:

```puppet
$array = [one, two, three, four]
```

becomes:

```puppet
$array = [
    one,
    two,
    three,
    four,
]
```

Nested commas must not be split at the outer collection level:

```puppet
$data = {
    'one' => func($a, $b),
    'two' => [1, 2, 3],
}
```

> **Note:** This section describes the planned configurable collection-layout behavior. Remove the "Planned" label once these options are present in the CLI.

---

# Multiline strings and heredocs

The formatter protects multiline string content from indentation and trailing-whitespace rewrites.

Example:

```puppet
$value = 'line one
line two
line three
'
```

The physical lines inside the string are not re-indented.

Interpolated double-quoted multiline strings are also protected, including lexer sequences such as `DQPRE`, `DQMID`, and `DQPOST`.

Heredoc content is likewise treated as protected content.

This is important because whitespace inside a heredoc or multiline string may be semantically significant.

---

# Trailing whitespace

Trailing spaces and tabs are removed from ordinary Puppet source lines.

Example:

```puppet
discovery_nodes => [    
```

becomes:

```puppet
discovery_nodes => [
```

Likewise:

```puppet
}    
```

becomes:

```puppet
}
```

Trailing whitespace is **not removed inside protected heredocs or multiline strings**.

A useful verification command is:

```bash
git diff --check
```

---

# Resource relationships

Relationship operators such as:

```puppet
->
~>
```

are preserved rather than aligned or rewritten as hash rockets.

Example:

```puppet
file {
    '/tmp/a':
        ensure => file;
}
-> service {
    'example':
        ensure => running;
}
```

The formatter may normalize the leading indentation of the relationship line, but does not treat `->` or `~>` as `=>`.

---

# Formatting pipeline

The formatter follows a staged approach:

1. Validate the original Puppet source.
2. Lex the original source with `puppet-lint`.
3. Normalize resource layout.
4. Re-lex after any inserted/removed line breaks.
5. Calculate structural nesting depth.
6. Calculate extra resource-parameter depth.
7. Detect protected heredoc/multiline-string lines.
8. Detect relationship lines.
9. Rewrite indentation.
10. Normalize hash rockets, if enabled.
11. Align sequential hash rockets, if enabled.
12. Align hash rockets by indentation/block, if enabled.
13. Normalize assignments, if enabled.
14. Align sequential assignments, if enabled.
15. Re-lex the final result.
16. Recalculate protected multiline lines.
17. Remove trailing whitespace outside protected content.
18. Validate the formatted Puppet source.

Re-lexing after passes that change physical line numbers is important because lexer token `line` and `column` information must match the current source.

---

# UTF-8 safety

Source edits are applied using byte offsets.

This is important for manifests containing non-ASCII text, for example:

```puppet
String $script_path, # скрипт для выполнения API call
```

Ruby character indexes and lexer byte-oriented positions can diverge after UTF-8 multibyte characters.

The formatter therefore performs offset-based source edits on a binary copy of the string and restores the original encoding afterwards.

---

# Recommended defaults

A practical configuration is:

```ruby
check: false,
diff: false,
indent_width: 4,

normalize_rockets: true,
align_rockets_sequential: false,
align_rockets_by_indent: false,
align_rockets_oneline: false,

normalize_assignments: false,
align_assignments_sequential: false,

split_empty_resource_body: true,
```

If/when collection-layout options are enabled:

```ruby
array_layout: :preserve,
hash_layout: :preserve,
```

---

# Example configurations

## Minimal formatting

Normalize indentation and basic rocket spacing, but avoid visual alignment:

```bash
puppet-format-4sp \
  --normalize-rockets \
  --no-align-rockets-sequential \
  --no-align-rockets-by-indent \
  --no-align-assignments-sequential \
  manifest.pp
```

## More aggressive alignment

```bash
puppet-format-4sp \
  --normalize-rockets \
  --align-rockets-sequential \
  --align-assignments-sequential \
  manifest.pp
```

## CI check

```bash
puppet-format-4sp \
  --check \
  --diff \
  manifest.pp
```

---

# Design goals

`puppet-format-4sp` intentionally separates formatting concerns:

- structural indentation
- resource layout
- hash-rocket normalization
- hash-rocket alignment
- assignment normalization
- assignment alignment
- protected multiline content
- trailing-whitespace cleanup

This makes it possible to enable alignment without changing unrelated syntax, or normalize spacing without forcing every construct into one visual style.

The formatter also favors lexer-aware transformations over raw text splitting so that commas, braces, quotes, and interpolation inside nested expressions are less likely to be misinterpreted.

---

# Development / debugging

Useful token dump:

```ruby
tokens.each do |token|
  puts "#{token.type} line=#{token.line} column=#{token.column} value=#{token.value.inspect}"
end
```

`puppet-lint` token columns are 1-based, so an absolute byte offset can be calculated as:

```ruby
line_start_offset + token.column - 1
```

When debugging formatting differences:

```bash
puppet-format-4sp --check --diff manifest.pp
git diff --check
```

To make invisible whitespace visible:

```bash
sed -n '1,120p' manifest.pp | cat -A
```

---

# License

AAdd the license used by your repository here.Add the license used by your repository here.dd the license used by ymt-4sp` is distributed under the BSD 2-Clause License.

See [LICENSE](LICENSE) for the full license text.

SPDX-License-Identifier: BSD-2-Clauseur repository here.
