# frozen_string_literal: true
# SPDX-License-Identifier: BSD-2-Clause

require 'open3'

module PuppetFormat4sp
  # Adds the require paths of a gem installed for a different Ruby executable.
  # This is primarily useful when the formatter runs under Puppet's embedded
  # Ruby while puppet-lint is installed for the system Ruby.
  module DependencyLoader
    DEFAULT_SYSTEM_RUBY = '/usr/bin/ruby'

    module_function

    def add_system_gem_require_paths(name, ruby: ENV.fetch('PUPPET_FORMAT_SYSTEM_RUBY', DEFAULT_SYSTEM_RUBY))
      script = <<~'RUBY'
        require 'rubygems'
        Gem::Specification.find_by_name(ARGV.fetch(0)).full_require_paths.each { |path| puts path }
      RUBY

      output, status = Open3.capture2(ruby, '-e', script, name)
      return false unless status.success?

      output.each_line do |line|
        path = line.strip
        next if path.empty? || $LOAD_PATH.include?(path)

        $LOAD_PATH.unshift(path)
      end

      true
    rescue Errno::ENOENT
      false
    end
  end
end

require 'puppet'

begin
  require 'puppet-lint'
rescue LoadError
  PuppetFormat4sp::DependencyLoader.add_system_gem_require_paths('puppet-lint')
  require 'puppet-lint'
end

module PuppetFormat4sp
  class FormatError < StandardError; end

  class Formatter
    DEFAULT_INDENT_WIDTH = 4

    OPEN_TO_CLOSE = {
      LBRACE: :RBRACE,
      LBRACK: :RBRACK,
      LPAREN: :RPAREN,
    }.freeze
    CLOSE_TO_OPEN = OPEN_TO_CLOSE.invert.freeze

    LAYOUT_WHITESPACE_TYPES = %i[
      WHITESPACE
      INDENT
      NEWLINE
    ].freeze

    COMMENT_TYPES = %i[
      COMMENT
      SLASH_COMMENT
      MLCOMMENT
    ].freeze

    TRIVIA_TYPES = (LAYOUT_WHITESPACE_TYPES + COMMENT_TYPES).freeze

    HEREDOC_CONTENT_TYPES = %i[
      HEREDOC
      HEREDOC_PRE
      HEREDOC_MID
      HEREDOC_POST
    ].freeze

    MULTILINE_STRING_TYPES = %i[
      STRING
      SSTRING
      DSTRING
      SQTEXT
      DQTEXT
    ].freeze

    RESOURCE_TITLE_VALUE_TYPES = %i[
      SSTRING
      STRING
      DSTRING
      DQPOST
      VARIABLE
      NAME
      DEFAULT
    ].freeze

    RESOURCE_DECLARATION_NAME_TYPES = %i[
      NAME
      TYPE
      CLASSREF
    ].freeze

    NON_RESOURCE_PREFIX_TYPES = %i[
      CLASS
      DEFINE
      FUNCTION
      NODE
      APPLICATION
    ].freeze

    RELATIONSHIP_TYPES = %i[
      IN_EDGE
      OUT_EDGE
      IN_EDGE_SUB
      OUT_EDGE_SUB
    ].freeze

    HASH_ROCKET_TYPE = :FARROW
    ASSIGNMENT_TYPE = :EQUALS

    def initialize(
      source,
      filename: '(string)',
      indent_width: DEFAULT_INDENT_WIDTH,
      normalize_rockets: true,
      align_rockets_sequential: true,
      align_rockets_by_indent: false,
      align_rockets_oneline: false,
      normalize_assignments: false,
      align_assignments_sequential: false,
      split_empty_resource_body: true
    )
      raise ArgumentError, 'indent_width must be greater than zero' unless indent_width.positive?

      @source = source
      @filename = filename
      @indent_width = indent_width
      @normalize_rockets = normalize_rockets
      @align_rockets_sequential = align_rockets_sequential
      @align_rockets_by_indent = align_rockets_by_indent
      @align_rockets_oneline = align_rockets_oneline
      @normalize_assignments = normalize_assignments
      @align_assignments_sequential = align_assignments_sequential
      @split_empty_resource_body = split_empty_resource_body
    end

    def format
      validate!(@source)

      current = @source
      tokens = lex(current)

      current = normalize_resource_layout(current, tokens)
      tokens = lex(current)

      structural_depths = calculate_structural_depths(tokens)
      resource_extra_depths = calculate_resource_extra_depths(tokens)
      protected_lines = calculate_protected_lines(tokens)
      relationship_lines = calculate_relationship_lines(tokens)

      result = rewrite_indentation(
        current,
        structural_depths,
        resource_extra_depths,
        protected_lines,
        relationship_lines
      )

      if @normalize_rockets
        tokens = lex(result)
        protected_lines = calculate_protected_lines(tokens)
        result = normalize_hash_rocket_spacing(result, tokens, protected_lines)
      end

      if @align_rockets_sequential || @align_rockets_by_indent
        tokens = lex(result)
        protected_lines = calculate_protected_lines(tokens)
        relationship_lines = calculate_relationship_lines(tokens)
        block_ids = calculate_block_ids(tokens)

        result = align_hash_rockets(
          result,
          tokens,
          protected_lines,
          relationship_lines,
          block_ids
        )
      end

      if @normalize_assignments || @align_assignments_sequential
        tokens = lex(result)
        protected_lines = calculate_protected_lines(tokens)
        result = format_assignments(result, tokens, protected_lines)
      end

      final_tokens = lex(result)
      final_protected_lines = calculate_protected_lines(final_tokens, include_opening_line: true)
      result = remove_trailing_whitespace(result, final_protected_lines)

      validate!(result)
      result
    end

    private

    # Parsing and token helpers

    def lex(text)
      PuppetLint::Lexer.new.tokenise(text)
    rescue StandardError => e
      raise FormatError,
            "#{@filename}: puppet-lint lexer error: #{e.message}",
            cause: e
    end

    def validate!(text)
      Puppet::Pops::Parser::EvaluatingParser.new.parse_string(text, @filename)
      true
    rescue StandardError => e
      raise FormatError,
            "#{@filename}: Puppet parse error: #{e.message}",
            cause: e
    end

    def significant_token?(token)
      !TRIVIA_TYPES.include?(token.type) &&
        !HEREDOC_CONTENT_TYPES.include?(token.type)
    end

    def significant_tokens(tokens)
      tokens.select { |token| significant_token?(token) }
    end

    def tokens_by_line(tokens)
      tokens.group_by(&:line)
    end

    def significant_line_tokens(line_tokens)
      line_tokens.select { |token| significant_token?(token) }
    end

    def token_source(token)
      if token.respond_to?(:to_manifest)
        token.to_manifest.to_s
      elsif token.respond_to?(:value)
        token.value.to_s
      else
        ''
      end
    end

    def token_width(token)
      token_source(token).bytesize
    end

    def line_start_offsets(text)
      offsets = [0]
      offset = 0

      text.each_line do |line|
        offset += line.bytesize
        offsets << offset
      end

      offsets
    end

    # puppet-lint 5.x reports one-based, byte-oriented columns.
    def token_offset(token, line_offsets)
      line_offsets.fetch(token.line - 1) + token.column - 1
    end

    # Source edits

    def apply_source_edits(text, edits)
      return text if edits.empty?

      unique_edits = edits.uniq.sort_by { |start_offset, end_offset, _| [start_offset, end_offset] }
      validate_source_edits!(text, unique_edits)

      original_encoding = text.encoding
      result = text.dup.force_encoding(Encoding::BINARY)

      unique_edits.reverse_each do |start_offset, end_offset, replacement|
        result[start_offset...end_offset] = replacement.dup.force_encoding(Encoding::BINARY)
      end

      result.force_encoding(original_encoding)
    end

    def validate_source_edits!(text, edits)
      previous_end = 0

      edits.each do |start_offset, end_offset, _replacement|
        unless start_offset.between?(0, text.bytesize) &&
               end_offset.between?(start_offset, text.bytesize)
          raise FormatError,
                "#{@filename}: invalid source edit #{start_offset}...#{end_offset}"
        end

        if start_offset < previous_end
          raise FormatError,
                "#{@filename}: overlapping source edits near byte #{start_offset}"
        end

        previous_end = end_offset
      end
    end

    def token_index_by_identity(tokens)
      tokens.each_with_index.to_h { |token, index| [token.object_id, index] }
    end

    def replace_inline_token_gap!(
      edits,
      tokens,
      token_indexes,
      left_token,
      right_token,
      line_offsets,
      replacement,
      allow_adjacent: false
    )
      return unless left_token.line == right_token.line

      left_index = token_indexes.fetch(left_token.object_id)
      right_index = token_indexes.fetch(right_token.object_id)
      return unless right_index > left_index

      gap_tokens = tokens[(left_index + 1)...right_index]
      return unless gap_tokens.all? { |token| token.type == :WHITESPACE }

      left_end = token_offset(left_token, line_offsets) + token_width(left_token)
      right_start = token_offset(right_token, line_offsets)
      return if right_start < left_end
      return if right_start == left_end && !allow_adjacent
      return if right_start == left_end && replacement.empty?

      edits << [left_end, right_start, replacement]
    end

    def preferred_newline(text)
      text.include?("\r\n") ? "\r\n" : "\n"
    end

    # Resource layout

    def normalize_resource_layout(text, tokens)
      significant = significant_tokens(tokens)
      token_indexes = token_index_by_identity(tokens)
      line_offsets = line_start_offsets(text)
      newline = preferred_newline(text)
      edits = []
      stack = []

      significant.each_with_index do |token, index|
        type = token.type

        if OPEN_TO_CLOSE.key?(type)
          resource = type == :LBRACE && resource_opening_brace?(significant, index)

          stack << {
            type: type,
            resource: resource,
            in_parameters: false,
          }

          if resource
            next_token = significant[index + 1]
            if next_token
              replace_inline_token_gap!(
                edits,
                tokens,
                token_indexes,
                token,
                next_token,
                line_offsets,
                newline,
                allow_adjacent: true
              )
            end
          end

          next
        end

        if resource_title_colon?(significant, index, stack)
          next_token = significant[index + 1]
          stack.last[:in_parameters] = true

          if next_token&.type == :SEMIC
            replacement = @split_empty_resource_body ? newline : ''

            replace_inline_token_gap!(
              edits,
              tokens,
              token_indexes,
              token,
              next_token,
              line_offsets,
              replacement,
              allow_adjacent: true
            )
          elsif next_token
            replace_inline_token_gap!(
              edits,
              tokens,
              token_indexes,
              token,
              next_token,
              line_offsets,
              newline,
              allow_adjacent: true
            )
          end

          next
        end

        if type == :COMMA && directly_inside_resource_parameters?(stack)
          next_token = significant[index + 1]

          if next_token
            replace_inline_token_gap!(
              edits,
              tokens,
              token_indexes,
              token,
              next_token,
              line_offsets,
              newline,
              allow_adjacent: true
            )
          end

          next
        end

        if type == :SEMIC && directly_inside_resource?(stack)
          next_token = significant[index + 1]

          if next_token
            replace_inline_token_gap!(
              edits,
              tokens,
              token_indexes,
              token,
              next_token,
              line_offsets,
              newline,
              allow_adjacent: true
            )
          end

          stack.last[:in_parameters] = false
          next
        end

        if CLOSE_TO_OPEN.key?(type)
          stack.pop unless stack.empty?
        end
      end

      apply_source_edits(text, edits)
    end

    def resource_title_colon?(tokens, index, stack)
      token = tokens[index]
      return false unless token.type == :COLON
      return false if stack.empty?

      frame = stack.last
      return false unless frame[:type] == :LBRACE && frame[:resource]

      previous = index.positive? ? tokens[index - 1] : nil
      previous && RESOURCE_TITLE_VALUE_TYPES.include?(previous.type)
    end

    def directly_inside_resource?(stack)
      !stack.empty? && stack.last[:resource]
    end

    def directly_inside_resource_parameters?(stack)
      !stack.empty? &&
        stack.last[:resource] &&
        stack.last[:in_parameters]
    end

    def resource_opening_brace?(tokens, index)
      token = tokens[index]
      return false unless token.type == :LBRACE
      return false if index.zero?

      previous = tokens[index - 1]
      return true if previous.type == :CLASS
      return false unless RESOURCE_DECLARATION_NAME_TYPES.include?(previous.type)

      prefix = index >= 2 ? tokens[index - 2] : nil
      !prefix || !NON_RESOURCE_PREFIX_TYPES.include?(prefix.type)
    end

    # Structural indentation

    def calculate_structural_depths(tokens)
      depths = {}
      stack = []

      significant_tokens(tokens).each do |token|
        type = token.type

        if CLOSE_TO_OPEN.key?(type)
          pop_expected!(stack, type, token)
          depths[token.line] ||= stack.length
          next
        end

        depths[token.line] ||= stack.length
        stack << { type: type, line: token.line } if OPEN_TO_CLOSE.key?(type)
      end

      unless stack.empty?
        open = stack.last
        raise FormatError,
              "#{@filename}: unmatched #{open[:type]} opened on line #{open[:line]}"
      end

      depths
    end

    def calculate_resource_extra_depths(tokens)
      extra_depths = {}
      stack = []
      next_frame_id = 0
      active_resource_frame_id = nil
      significant = significant_tokens(tokens)

      significant.each_with_index do |token, index|
        type = token.type
        line = token.line

        extra_depths[line] = 1 if active_resource_frame_id

        if resource_title_colon?(significant, index, stack)
          next_token = significant[index + 1]
          extra_depths.delete(line)

          active_resource_frame_id =
            if next_token&.type == :SEMIC && next_token.line == line
              nil
            else
              stack.last[:id]
            end
        end

        active_resource_frame_id = nil if type == :SEMIC

        if OPEN_TO_CLOSE.key?(type)
          next_frame_id += 1
          stack << {
            id: next_frame_id,
            type: type,
            resource: resource_opening_brace?(significant, index),
          }
          next
        end

        next unless CLOSE_TO_OPEN.key?(type)

        frame = stack.last
        if type == :RBRACE &&
           frame&.dig(:type) == :LBRACE &&
           frame[:resource] &&
           active_resource_frame_id == frame[:id]
          extra_depths.delete(line)
          active_resource_frame_id = nil
        end

        stack.pop unless stack.empty?
      end

      extra_depths
    end

    def pop_expected!(stack, closing_type, token)
      expected_open = CLOSE_TO_OPEN.fetch(closing_type)
      actual = stack.pop

      if actual.nil?
        raise FormatError,
              "#{@filename}:#{token.line}:#{safe_column(token)}: unexpected #{closing_type}"
      end

      return if actual[:type] == expected_open

      raise FormatError,
            "#{@filename}:#{token.line}:#{safe_column(token)}: " \
            "unexpected #{closing_type}; currently inside #{actual[:type]}"
    end

    def safe_column(token)
      token.respond_to?(:column) ? token.column : 1
    end

    def calculate_block_ids(tokens)
      line_blocks = {}
      stack = []
      next_id = 0

      significant_tokens(tokens).each do |token|
        type = token.type

        if CLOSE_TO_OPEN.key?(type)
          stack.pop unless stack.empty?
          line_blocks[token.line] ||= stack.last&.fetch(:id)
          next
        end

        line_blocks[token.line] ||= stack.last&.fetch(:id)
        next unless OPEN_TO_CLOSE.key?(type)

        next_id += 1
        stack << { id: next_id, type: type }
      end

      line_blocks
    end

    # Protected multiline content

    def calculate_protected_lines(tokens, include_opening_line: false)
      protected = {}
      double_quote_start_line = nil

      tokens.each do |token|
        case token.type
        when :DQPRE
          double_quote_start_line ||= token.line
        when :DQMID
          double_quote_start_line ||= token.line
        when :DQPOST
          if double_quote_start_line
            end_line = token.line + newline_count(token_source(token))
            first_line = include_opening_line ? double_quote_start_line : double_quote_start_line + 1
            mark_line_range!(protected, first_line, end_line)
            double_quote_start_line = nil
          else
            protect_multiline_token!(
              protected,
              token,
              skip_first_line: !include_opening_line
            )
          end
        else
          if HEREDOC_CONTENT_TYPES.include?(token.type)
            protect_multiline_token!(protected, token, skip_first_line: false)
          elsif multiline_string_token?(token)
            protect_multiline_token!(
              protected,
              token,
              skip_first_line: !include_opening_line
            )
          end
        end
      end

      protected
    end

    def protect_multiline_token!(protected, token, skip_first_line:)
      rendered = token_source(token)
      count = newline_count(rendered)
      return if count.zero?

      first_line = skip_first_line ? token.line + 1 : token.line
      mark_line_range!(protected, first_line, token.line + count)
    end

    def multiline_string_token?(token)
      MULTILINE_STRING_TYPES.include?(token.type) &&
        newline_count(token_source(token)).positive?
    end

    def newline_count(text)
      text.count("\n")
    end

    def mark_line_range!(lines, first_line, last_line)
      return if last_line < first_line

      first_line.upto(last_line) { |line| lines[line] = true }
    end

    # Relationship lines

    def calculate_relationship_lines(tokens)
      relationships = {}

      tokens_by_line(tokens).each do |line_number, line_tokens|
        first = line_tokens.find do |token|
          !LAYOUT_WHITESPACE_TYPES.include?(token.type) &&
            !COMMENT_TYPES.include?(token.type)
        end

        relationships[line_number] = true if first && RELATIONSHIP_TYPES.include?(first.type)
      end

      relationships
    end

    # Indentation rewriting

    def rewrite_indentation(
      text,
      structural_depths,
      resource_extra_depths,
      protected_lines,
      relationship_lines
    )
      effective_depths = structural_depths.to_h do |line, depth|
        [line, depth + resource_extra_depths.fetch(line, 0)]
      end
      comment_depths = calculate_comment_depths(text, effective_depths)

      text.lines.each_with_index.map do |line, index|
        line_number = index + 1

        next line if protected_lines[line_number]
        next line if line.strip.empty?
        next line if relationship_lines[line_number]

        depth = effective_depths[line_number] || comment_depths[line_number]
        next line if depth.nil?

        replace_leading_whitespace(line, depth)
      end.join
    end

    def calculate_comment_depths(text, depths)
      line_count = text.lines.length
      previous = Array.new(line_count + 1)
      following = Array.new(line_count + 1)
      current = nil

      1.upto(line_count) do |line_number|
        previous[line_number] = current
        current = depths[line_number] if depths.key?(line_number)
      end

      current = nil
      line_count.downto(1) do |line_number|
        following[line_number] = current
        current = depths[line_number] if depths.key?(line_number)
      end

      result = {}
      text.lines.each_with_index do |line, index|
        line_number = index + 1
        next unless comment_only_line?(line)

        neighboring = [previous[line_number], following[line_number]].compact
        result[line_number] = neighboring.empty? ? 0 : neighboring.min
      end

      result
    end

    def comment_only_line?(line)
      stripped = strip_leading_spaces_tabs(line)
      stripped.start_with?('#', '//', '/*', '*')
    end

    def replace_leading_whitespace(line, depth)
      body, newline = split_line_ending(line)
      body = strip_leading_spaces_tabs(body)
      (' ' * (depth * @indent_width)) + body + newline
    end

    # Hash rocket normalization and alignment

    def normalize_hash_rocket_spacing(text, tokens, protected_lines)
      line_offsets = line_start_offsets(text)
      edits = []

      tokens.each_with_index do |token, index|
        next unless token.type == HASH_ROCKET_TYPE
        next if protected_lines[token.line]

        normalize_inline_operator_spacing!(
          edits,
          tokens,
          index,
          line_offsets,
          token_width(token)
        )
      end

      apply_source_edits(text, edits)
    end

    def normalize_inline_operator_spacing!(edits, tokens, index, line_offsets, operator_width)
      operator = tokens[index]
      operator_start = token_offset(operator, line_offsets)
      operator_end = operator_start + operator_width
      previous = index.positive? ? tokens[index - 1] : nil
      following = tokens[index + 1]

      if previous && previous.line == operator.line
        before_start =
          if previous.type == :WHITESPACE
            token_offset(previous, line_offsets)
          else
            operator_start
          end
        edits << [before_start, operator_start, ' ']
      end

      if following && following.line == operator.line
        after_end =
          if following.type == :WHITESPACE
            token_offset(following, line_offsets) + token_width(following)
          else
            operator_end
          end
        edits << [operator_end, after_end, ' ']
      end
    end

    def align_hash_rockets(text, tokens, protected_lines, relationship_lines, block_ids)
      entries = operator_line_entries(
        text,
        tokens,
        HASH_ROCKET_TYPE,
        protected_lines,
        relationship_lines
      )
      target_widths = {}

      if @align_rockets_sequential
        sequential_operator_groups(entries).each do |group|
          record_group_widths!(target_widths, group)
        end
      end

      if @align_rockets_by_indent
        entries
          .group_by { |entry| [block_ids[entry[:line_number]], entry[:indent].bytesize] }
          .each_value do |group|
            record_group_widths!(target_widths, group) if group.length > 1
          end
      end

      rewrite_operator_entries(text, entries, target_widths, '=>')
    end

    def operator_line_entries(text, tokens, operator_type, protected_lines, excluded_lines = {})
      lines = text.lines
      entries = []

      tokens_by_line(tokens).each do |line_number, line_tokens|
        next if protected_lines[line_number] || excluded_lines[line_number]

        operators = line_tokens.select { |token| token.type == operator_type }
        next if operators.empty?

        operator = operators.first
        if operator_type == HASH_ROCKET_TYPE &&
           !@align_rockets_oneline &&
           inline_structural_operator?(line_tokens, operator)
          next
        end

        entry = split_operator_line(lines.fetch(line_number - 1), operator, token_width(operator))
        next unless entry

        entry[:line_number] = line_number
        entry[:line_index] = line_number - 1
        entries << entry
      end

      entries.sort_by { |entry| entry[:line_number] }
    end

    def inline_structural_operator?(line_tokens, operator)
      significant = significant_line_tokens(line_tokens)
      index = significant.index(operator)
      return false unless index

      significant[0...index].any? { |token| token.type == :LBRACE } &&
        significant[(index + 1)..].any? { |token| token.type == :RBRACE }
    end

    def sequential_operator_groups(entries)
      groups = []
      current = []

      entries.each do |entry|
        if current.empty? ||
           (entry[:line_number] == current.last[:line_number] + 1 &&
            entry[:indent] == current.last[:indent])
          current << entry
        else
          groups << current if current.length > 1
          current = [entry]
        end
      end

      groups << current if current.length > 1
      groups
    end

    def record_group_widths!(target_widths, group)
      width = group.map { |entry| entry[:left].length }.max
      group.each do |entry|
        line_number = entry[:line_number]
        target_widths[line_number] = [target_widths.fetch(line_number, 0), width].max
      end
    end

    def rewrite_operator_entries(text, entries, target_widths, operator_text, rewrite_all: false)
      lines = text.lines

      entries.each do |entry|
        width = target_widths[entry[:line_number]]
        next unless rewrite_all || width

        width ||= entry[:left].length
        padding = ' ' * (width - entry[:left].length + 1)

        lines[entry[:line_index]] =
          entry[:indent] +
          entry[:left] +
          padding +
          operator_text +
          (entry[:right].empty? ? '' : ' ') +
          entry[:right] +
          entry[:newline]
      end

      lines.join
    end

    def split_operator_line(line, operator, operator_width)
      body, newline = split_line_ending(line)
      binary = body.dup.force_encoding(Encoding::BINARY)
      original_encoding = body.encoding
      operator_offset = operator.column - 1
      indent_width = leading_space_tab_count(body)
      return nil if operator_offset < indent_width || operator_offset + operator_width > binary.bytesize

      indent = binary.byteslice(0, indent_width).to_s
      left = binary.byteslice(indent_width, operator_offset - indent_width).to_s
      right = binary.byteslice(operator_offset + operator_width..).to_s

      [indent, left, right].each { |part| part.force_encoding(original_encoding) }
      left = trim_trailing_spaces_tabs(left)
      right = strip_leading_spaces_tabs(right)
      return nil if left.empty?

      {
        indent: indent,
        left: left,
        right: right,
        newline: newline,
      }
    end

    # Assignment normalization and alignment

    def format_assignments(text, tokens, protected_lines)
      entries = assignment_entries(text, tokens, protected_lines)
      target_widths = {}

      if @align_assignments_sequential
        sequential_operator_groups(entries).each do |group|
          record_group_widths!(target_widths, group)
        end
      end

      rewrite_operator_entries(
        text,
        entries,
        target_widths,
        '=',
        rewrite_all: @normalize_assignments
      )
    end

    def assignment_entries(text, tokens, protected_lines)
      lines = text.lines
      entries = []

      tokens_by_line(tokens).each do |line_number, line_tokens|
        next if protected_lines[line_number]

        significant = significant_line_tokens(line_tokens)
        next unless significant.length >= 3
        next unless significant[0].type == :VARIABLE
        next unless significant[1].type == ASSIGNMENT_TYPE

        operator = significant[1]
        entry = split_operator_line(lines.fetch(line_number - 1), operator, token_width(operator))
        next unless entry

        entry[:line_number] = line_number
        entry[:line_index] = line_number - 1
        entries << entry
      end

      entries.sort_by { |entry| entry[:line_number] }
    end

    # Whitespace helpers

    def split_line_ending(line)
      if line.end_with?("\r\n")
        [line.byteslice(0, line.bytesize - 2), "\r\n"]
      elsif line.end_with?("\n")
        [line.byteslice(0, line.bytesize - 1), "\n"]
      else
        [line, '']
      end
    end

    def leading_space_tab_count(text)
      binary = text.dup.force_encoding(Encoding::BINARY)
      index = 0

      while index < binary.bytesize
        byte = binary.getbyte(index)
        break unless byte == 32 || byte == 9

        index += 1
      end

      index
    end

    def strip_leading_spaces_tabs(text)
      count = leading_space_tab_count(text)
      return text if count.zero?

      result = text.byteslice(count..).to_s
      result.force_encoding(text.encoding)
    end

    def trim_trailing_spaces_tabs(text)
      binary = text.dup.force_encoding(Encoding::BINARY)
      index = binary.bytesize

      while index.positive?
        byte = binary.getbyte(index - 1)
        break unless byte == 32 || byte == 9

        index -= 1
      end

      result = binary.byteslice(0, index).to_s
      result.force_encoding(text.encoding)
    end

    def remove_trailing_whitespace(text, protected_lines)
      text.lines.each_with_index.map do |line, index|
        line_number = index + 1
        next line if protected_lines[line_number]

        body, newline = split_line_ending(line)
        trim_trailing_spaces_tabs(body) + newline
      end.join
    end
  end
end
