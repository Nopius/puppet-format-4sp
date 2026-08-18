# SPDX-License-Identifier: BSD-2-Clause

require 'open3'

# we should will internal 'ruby' puppet gem and system wide installed gem 'puppet-lint'
def system_gem_lib(name)
  ruby = '/usr/bin/ruby'

  code = <<~'RUBY'
    require 'rubygems'
    spec = Gem::Specification.find_by_name(ARGV[0])
    puts spec.full_require_paths
  RUBY

  output, status = Open3.capture2(
    ruby,
    '-e', code,
    name
  )

  return [] unless status.success?

  output.lines.map(&:strip).reject(&:empty?)
end

system_gem_lib('puppet-lint').each do |path|
  $LOAD_PATH.unshift(path)
end

require 'puppet'
require 'puppet-lint'

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

    TRIVIA = %i[
      WHITESPACE
      INDENT
      NEWLINE
      COMMENT
      SLASH_COMMENT
      MLCOMMENT
    ].freeze

    HEREDOC_CONTENT = %i[
      HEREDOC
      HEREDOC_PRE
      HEREDOC_MID
      HEREDOC_POST
    ].freeze

    RELATIONSHIP_TYPES = %i[
      IN_EDGE
      OUT_EDGE
      IN_EDGE_SUB
      OUT_EDGE_SUB
    ].freeze

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

      tokens = lex(@source)

      source = normalize_resource_layout(
        @source,
        tokens
      )

      tokens = lex(source)


      structural_depths = calculate_structural_depths(tokens)
      resource_extra_depths =
        calculate_resource_extra_depths(tokens)

      block_ids = calculate_block_ids(tokens)
      protected_lines = calculate_protected_lines(tokens)
      relationship_lines = calculate_relationship_lines(tokens)

      result = rewrite_indentation(
        source,
        structural_depths,
        resource_extra_depths,
        protected_lines,
        relationship_lines
      )

      if normalize_rockets
        result = normalize_hash_rocket_spacing(
          result,
          protected_lines
        )
      end

      if align_rockets_sequential
        result = align_hash_rockets_sequential(
          result,
          protected_lines,
          relationship_lines
        )
      end

      if align_rockets_by_indent
        result = align_hash_rockets_by_indent(
          result,
          protected_lines,
          relationship_lines,
          block_ids
        )
      end

      if normalize_assignments
        result = normalize_assignment_spacing(
          result,
          protected_lines
        )
      end

      if align_assignments_sequential
        result = align_assignments_sequential_pass(
          result,
          protected_lines
        )
      end

      # Recalculate protection against the final text.
      final_tokens = lex(result)
      final_protected_lines = calculate_protected_lines(final_tokens)
      # Final cleanup.
      result = remove_trailing_whitespace(
        result,
        final_protected_lines
      )

      validate!(result)

      result
    end

    private

    attr_reader(
      :source,
      :filename,
      :indent_width,
      :normalize_rockets,
      :align_rockets_sequential,
      :align_rockets_by_indent,
      :align_rockets_oneline,
      :normalize_assignments,
      :align_assignments_sequential
    )

    #
    # Parsing / lexing
    #

    def lex(text)
      lexer = PuppetLint::Lexer.new
      lexer.tokenise(text)
    rescue StandardError => e
      raise FormatError,
            "#{@filename}: puppet-lint lexer error: #{e.message}"
    end

    def validate!(text)
      parser = Puppet::Pops::Parser::EvaluatingParser.new
      parser.parse_string(text, @filename)

      true
    rescue StandardError => e
      raise FormatError,
            "#{@filename}: Puppet parse error: #{e.message}"
    end

    def significant_tokens(tokens)
      tokens.reject do |token|
        TRIVIA.include?(token.type) ||
          HEREDOC_CONTENT.include?(token.type)
      end
    end

  
    def resource_title_colon?(tokens, index, stack)
      token = tokens[index]
    
      return false unless token.type == :COLON
      return false if stack.empty?
    
      #
      # Only a colon inside a resource-declaration {...} can introduce
      # resource parameter indentation.
      #
      return false unless stack.last[:type] == :LBRACE
      return false unless stack.last[:resource]
    
      previous = index.positive? ? tokens[index - 1] : nil
      return false unless previous
    
      resource_title_value_token?(previous)
    end

    def directly_inside_resource?(stack)
      return false if stack.empty?
      stack.last[:resource] == true
    end

    def directly_inside_resource_parameters?(stack)
      return false if stack.empty?
    
      frame = stack.last
    
      frame[:resource] == true &&
        frame[:in_parameters] == true
    end
   
    def normalize_empty_resource_separator!(
      edits,
      text,
      colon_token,
      semicolon_token,
      line_offsets
    )
      colon_offset = token_offset(colon_token, line_offsets)
      semicolon_offset = token_offset(semicolon_token, line_offsets)
    
      colon_end = colon_offset + 1
    
      return if semicolon_offset < colon_end
    
      between = text.byteslice(
        colon_end,
        semicolon_offset - colon_end
      ) || ''
    
      return unless between.match?(/\A[ \t]*\z/)
    
      edits << [
        colon_end,
        semicolon_offset,
        '',
      ]
    end

    def remove_trailing_whitespace(text, protected_lines)
      text.lines.each_with_index.map do |line, index|
        line_number = index + 1
    
        next line if protected_lines[line_number]
    
        newline = line[/\r?\n\z/] || ''
        body = line.sub(/\r?\n\z/, '')
    
        body.sub(/[ \t]+\z/, '') + newline
      end.join
    end
     
    def normalize_resource_layout(text, tokens)
      sig = significant_tokens(tokens)
      line_offsets = line_start_offsets(text)

      #
      # Each edit is:
      #
      #   [start_offset, end_offset, replacement]
      #
      # We only replace whitespace between significant tokens.
      #
      edits = []
    
      stack = []
    
      sig.each_with_index do |token, index|
        type = token.type
    
        #
        # Opening delimiter.
        #
        if OPEN_TO_CLOSE.key?(type)
          is_resource =
            type == :LBRACE &&
            resource_opening_brace?(sig, index)
        
          stack << {
            type: type,
            resource: is_resource,
            in_parameters: false,
          }
        
          if is_resource
            next_token = sig[index + 1]
        
            if next_token && next_token.line == token.line
              add_newline_between_tokens!(
                edits,
                text,
                token,
                next_token,
                line_offsets
              )
            end
          end
        
          next
        end
    
        #
        # Resource title:
        #
        #     $payload_file:
        #
        # First parameter must start on the next line.
        #
        if type == :COLON &&
          resource_title_colon?(sig, index, stack)
        
          next_token = sig[index + 1]
        
          #
          # From this point onward, top-level commas belong to
          # resource parameters.
          #
          stack.last[:in_parameters] = true
        
          if next_token&.type == :SEMIC
            if @split_empty_resource_body
              add_newline_between_tokens!(
                edits,
                text,
                token,
                next_token,
                line_offsets,
                allow_adjacent: true
              )
            else
              normalize_empty_resource_separator!(
                edits,
                text,
                token,
                next_token,
                line_offsets
              )
            end
        
          elsif next_token && next_token.line == token.line
            add_newline_between_tokens!(
              edits,
              text,
              token,
              next_token,
              line_offsets
            )
          end
        
          next
        end
 
        #
        # Top-level resource parameter separator.
        #
        # Only split commas belonging directly to the resource.
        #
        # Do NOT split:
        #
        #     foo => func($a, $b),
        #                    ^
        #
        #     foo => [1, 2, 3],
        #
        # because LPAREN/LBRACK will be the top stack frame there.
        #
        if type == :COMMA && directly_inside_resource_parameters?(stack)
          next_token = sig[index + 1]
    
          if next_token &&
             next_token.type != :RBRACE &&
             next_token.line == token.line
    
            add_newline_between_tokens!(
              edits,
              text,
              token,
              next_token,
              line_offsets
            )
          end
    
          next
        end
    
        #
        # Multiple resource titles can be separated by semicolon:
        #
        # file {
        #     '/a':
        #         ensure => file;
        #     '/b':
        #         ensure => file;
        # }
        #
        if type == :SEMIC && directly_inside_resource?(stack)
          next_token = sig[index + 1]
    
          if next_token &&
             next_token.type != :RBRACE &&
             next_token.line == token.line
    
            add_newline_between_tokens!(
              edits,
              text,
              token,
              next_token,
              line_offsets
            )
          end
    
          next
        end
    
        #
        # Closing delimiter.
        #
        if CLOSE_TO_OPEN.key?(type)
          stack.pop unless stack.empty?
        end
      end
    
      apply_source_edits(text, edits)
    end


    def add_newline_between_tokens!(
      edits,
      text,
      left_token,
      right_token,
      line_offsets,
      allow_adjacent: false
    )
      left_offset = token_offset(left_token, line_offsets)
      right_offset = token_offset(right_token, line_offsets)
    
      #
      # All tokens we use as the left-hand delimiter here are
      # one-character Puppet punctuation:
      #
      #     { : , ;
      #
      left_end = left_offset + 1
    
      return if right_offset < left_end
      return if right_offset == left_end && !allow_adjacent
    
      between = text.byteslice(
        left_end,
        right_offset - left_end
      ) || ''
    
      return unless between.match?(/\A[ \t]*\z/)   

      edits << [
        left_end,
        right_offset,
        "\n",
      ]
    end

    def apply_source_edits(text, edits)
      original_encoding = text.encoding
      result = text.dup.force_encoding(Encoding::BINARY)
    
      edits
        .uniq
        .sort_by { |start_offset, _end_offset, _replacement| -start_offset }
        .each do |start_offset, end_offset, replacement|
    
        result[start_offset...end_offset] =
          replacement.dup.force_encoding(Encoding::BINARY)
      end
    
      result.force_encoding(original_encoding)
    end

    def resource_title_value_token?(token)
      %i[
        SSTRING
        STRING
        DSTRING
        DQPOST
        VARIABLE
        NAME
        DEFAULT
      ].include?(token.type)
    end
    
    def previous_significant_token(tokens, index)
      i = index - 1
    
      while i >= 0
        token = tokens[i]
    
        return token unless TRIVIA.include?(token.type)
    
        i -= 1
      end
    
      nil
    end
    
    #
    # Structural indentation
    #
    def calculate_structural_depths(tokens)
      depths = {}
      stack = []
    
      significant_tokens(tokens).each do |token|
        type = token.type
        line = token.line
    
        if CLOSE_TO_OPEN.key?(type)
          pop_expected!(stack, type, token)
          depths[line] ||= stack.length
          next
        end
    
        depths[line] ||= stack.length
    
        if OPEN_TO_CLOSE.key?(type)
          stack << {
            type: type,
            line: line,
          }
        end
      end
    
      unless stack.empty?
        open = stack.last
    
        raise FormatError,
              "#{@filename}: unmatched #{open[:type]} " \
              "opened on line #{open[:line]}"
      end
    
      depths
    end

    def calculate_resource_extra_depths(tokens)
      extra_depths = {}
    
      stack = []
      next_frame_id = 0
      active_resource_frame_id = nil
    
      sig = significant_tokens(tokens)
    
      sig.each_with_index do |token, index|
        type = token.type
        line = token.line
    
        #
        # While a resource title is active, its parameter lines receive
        # one additional indentation level.
        #
        if active_resource_frame_id
          extra_depths[line] = 1
        end
    
        #
        # A title colon activates resource-parameter indentation
        # AFTER the title line.
        #
        if resource_title_colon?(sig, index, stack)
          next_token = sig[index + 1]
        
          #
          # The title line itself is never extra-indented.
          #
          extra_depths.delete(line)
        
          #
          # title:;
          #
          # No parameter/body line exists, so don't enter extra-depth mode.
          #
          if next_token&.type == :SEMIC &&
             next_token.line == line
            active_resource_frame_id = nil
          else
            #
            # Either real parameters follow, or the terminating semicolon
            # is on a following line:
            #
            #   'foo':
            #       ;
            #
            active_resource_frame_id = stack.last[:id]
          end
        end
 
        #
        # ';' terminates this resource instance.
        #
        # The semicolon line itself is still a parameter line.
        #
        if type == :SEMIC
          active_resource_frame_id = nil
        end
    
        #
        # Opening structural delimiter.
        #
        if OPEN_TO_CLOSE.key?(type)
          next_frame_id += 1
      
          stack << {
            id: next_frame_id,
            type: type,
            resource: resource_opening_brace?(sig, index),
          }
      
          next
        end

        #
        # Closing structural delimiter.
        #
        if CLOSE_TO_OPEN.key?(type)
          frame = stack.last
    
          if type == :RBRACE
            frame = stack.last
          
            if frame &&
               frame[:type] == :LBRACE &&
               frame[:resource] &&
               active_resource_frame_id == frame[:id]
          
              #
              # Closing brace belongs to the resource declaration level,
              # not the parameter level.
              #
              extra_depths.delete(line)
              active_resource_frame_id = nil
            end
          end
          
          stack.pop unless stack.empty?
        end
      end
    
      extra_depths
    end

    def resource_opening_brace?(tokens, index)
      token = tokens[index]
    
      return false unless token.type == :LBRACE
      return false if index.zero?
    
      previous = tokens[index - 1]
   
      #
      # Resource-like class declaration:
      #
      #     class {
      #         'foo':
      #             ...
      #     }
      #
      return true if previous.type == :CLASS
     
      #
      # A resource declaration looks like:
      #
      #   file {
      #   File {
      #   backup::custom_backup {
      #
      return false unless previous.type == :NAME
    
      #
      # Exclude constructs where NAME immediately before { is not
      # a resource type.
      #
      before_previous =
        index >= 2 ? tokens[index - 2] : nil
    
      return false if before_previous &&
                      %i[
                        CLASS
                        DEFINE
                        FUNCTION
                        NODE
                        APPLICATION
                      ].include?(before_previous.type)
    
      true
    end

    def resource_semicolon?(token)
      token.type == :SEMIC
    end

    def pop_expected!(stack, closing_type, token)
      expected_open = CLOSE_TO_OPEN.fetch(closing_type)
      actual = stack.pop

      if actual.nil?
        raise FormatError,
              "#{@filename}:#{token.line}:#{safe_column(token)}: " \
              "unexpected #{closing_type}"
      end

      return if actual[:type] == expected_open

      raise FormatError,
            "#{@filename}:#{token.line}:#{safe_column(token)}: " \
            "unexpected #{closing_type}; " \
            "currently inside #{actual[:type]}"
    end

    def safe_column(token)
      token.respond_to?(:column) ? token.column : 1
    end

    #
    # Structural block IDs
    #
    # Used to distinguish:
    #
    #   outer undef/default
    #
    # from:
    #
    #   nested undef/default
    #
    def calculate_block_ids(tokens)
      line_blocks = {}
      stack = []
      next_id = 0

      significant_tokens(tokens).each do |token|
        type = token.type
        line = token.line

        if CLOSE_TO_OPEN.key?(type)
          stack.pop unless stack.empty?
          line_blocks[line] ||= stack.last&.fetch(:id)
          next
        end

        line_blocks[line] ||= stack.last&.fetch(:id)

        next unless OPEN_TO_CLOSE.key?(type)

        next_id += 1

        stack << {
          id: next_id,
          type: type,
        }
      end

      line_blocks
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
    
    def protect_multiline_token!(
      protected,
      token,
      skip_first_line:
    )
      rendered = token_source(token)
    
      return unless rendered.include?("\n")
    
      start_line = token.line
      end_line = start_line + rendered.count("\n")
    
      first_protected_line =
        skip_first_line ? start_line + 1 : start_line
    
      first_protected_line.upto(end_line) do |line|
        protected[line] = true
      end
    end

    def multiline_string_token?(token)
      return false unless %i[
        STRING
        SSTRING
        DSTRING
        SQTEXT
        DQTEXT
      ].include?(token.type)
    
      token_source(token).include?("\n")
    end

    #
    # Heredocs
    #
    def calculate_protected_lines(tokens)
      protected = {}
    
      #
      # Puppet-lint represents interpolated double-quoted strings as:
      #
      #   DQPRE
      #   DQMID
      #   ...
      #   DQPOST
      #
      # Treat the complete sequence as one opaque source region.
      #
      dq_start_line = nil
    
      tokens.each do |token|
        type = token.type
    
        case type
        when :DQPRE
          #
          # Opening line still contains Puppet syntax, for example:
          #
          #   content => "first line
          #
          # so don't protect the opening line itself.
          #
          dq_start_line ||= token.line
    
        when :DQMID
          #
          # Still inside the same interpolated string.
          #
          dq_start_line ||= token.line
    
        when :DQPOST
          if dq_start_line
            rendered = token_source(token)
    
            end_line =
              token.line +
              rendered.count("\n")
    
            #
            # Everything after the opening physical line through the
            # closing quote line is opaque string content.
            #
            (dq_start_line + 1).upto(end_line) do |line|
              protected[line] = true
            end
    
            dq_start_line = nil
          else
            #
            # Defensive handling in case puppet-lint emits a standalone
            # multiline DQPOST.
            #
            protect_multiline_token!(
              protected,
              token,
              skip_first_line: true
            )
          end
    
        else
          #
          # Heredocs remain completely protected.
          #
          if HEREDOC_CONTENT.include?(type)
            protect_multiline_token!(
              protected,
              token,
              skip_first_line: false
            )
          elsif multiline_string_token?(token)
            protect_multiline_token!(
              protected,
              token,
              skip_first_line: true
            )
          end
        end
      end
    
      protected
    end

    #
    # Resource relationships
    #

    def calculate_relationship_lines(tokens)
      relationship_lines = {}

      tokens.each do |token|
        if RELATIONSHIP_TYPES.include?(token.type)
          relationship_lines[token.line] = true
        end
      end

      source.lines.each_with_index do |line, index|
        stripped = line.lstrip

        if stripped.start_with?('->', '~>')
          relationship_lines[index + 1] = true
        end
      end

      relationship_lines
    end

    #
    # Indentation rewriting
    #

    def rewrite_indentation(
      text,
      depths,
      resource_extra_depths,
      protected_lines,
      relationship_lines
    )
      lines = text.lines

      lines.each_with_index.map do |line, index|
        line_number = index + 1

        rewrite_line(
          line,
          line_number,
          depths,
          resource_extra_depths,
          protected_lines,
          relationship_lines
        )
      end.join
    end

    def rewrite_line(
      line,
      line_number,
      depths,
      resource_extra_depths,
      protected_lines,
      relationship_lines
    )
      return line if protected_lines[line_number]
      return line if line.strip.empty?
    
      if relationship_continuation_line?(
        line,
        line_number,
        relationship_lines
      )
        return line
      end
    
      depth = depths[line_number]
    
      if depth
        depth += resource_extra_depths.fetch(
          line_number,
          0
        )
      end
    
      depth ||= comment_depth(
        line,
        line_number,
        depths
      )
    
      return line if depth.nil?
    
      replace_leading_whitespace(line, depth)
    end


    def relationship_continuation_line?(
      line,
      line_number,
      relationship_lines
    )
      return false unless relationship_lines[line_number]

      stripped = line.lstrip

      stripped.start_with?('->', '~>')
    end

    def replace_leading_whitespace(line, depth)
      newline = newline_for(line)

      body = line.sub(/\r?\n\z/, '')
      body = body.sub(/\A[ \t]*/, '')

      (' ' * (depth * indent_width)) +
        body +
        newline
    end

    def comment_depth(line, line_number, depths)
      stripped = line.lstrip

      return nil unless stripped.start_with?(
        '#',
        '//',
        '/*',
        '*'
      )

      previous = previous_depth(line_number, depths)
      following = next_depth(line_number, depths)

      if previous && following
        [previous, following].min
      else
        previous || following || 0
      end
    end

    def previous_depth(line_number, depths)
      candidate =
        depths
        .select { |line, _depth| line < line_number }
        .max_by { |line, _depth| line }

      candidate&.last
    end

    def next_depth(line_number, depths)
      candidate =
        depths
        .select { |line, _depth| line > line_number }
        .min_by { |line, _depth| line }

      candidate&.last
    end

    #
    # => normalization
    #
    # This intentionally runs even for:
    #
    #   { foo       =>bar, baz=>   qux }
    #
    # producing:
    #
    #   { foo => bar, baz => qux }
    #
    def normalize_hash_rocket_spacing(text, protected_lines)
      lines = text.lines

      lines.each_with_index.map do |line, index|
        line_number = index + 1

        next line if protected_lines[line_number]
        next line unless line.include?('=>')

        normalize_rockets_in_line(line)
      end.join
    end

    def normalize_rockets_in_line(line)
      newline = newline_for(line)
      body = line.sub(/\r?\n\z/, '')

      #
      # Protect quoted strings before normalizing.
      #
      # This is intentionally conservative and avoids changing
      # "foo => bar" inside normal quoted strings.
      #
      segments = split_quoted_segments(body)

      normalized = segments.map do |segment|
        if segment[:quoted]
          segment[:text]
        else
          segment[:text].gsub(
            /[ \t]*=>[ \t]*/,
            ' => '
          )
        end
      end.join

      normalized + newline
    end

    def collect_sequential_rocket_groups(
      lines,
      protected_lines,
      relationship_lines
    )
      groups = []
      current = []
    
      lines.each_with_index do |line, index|
        line_number = index + 1
    
        candidate = hash_rocket_candidate?(
          line,
          line_number,
          protected_lines,
          relationship_lines
        )
    
        #
        # By default, complete one-line {... => ...} expressions do not
        # participate in alignment.
        #
        if candidate &&
           inline_structural_rocket_line?(line) &&
           !align_rockets_oneline
          candidate = false
        end
    
        if candidate
          indent = leading_indent_width(line)
    
          if current.empty?
            current << index
          elsif leading_indent_width(lines[current.last]) == indent
            current << index
          else
            groups << current if current.length > 1
            current = [index]
          end
        else
          groups << current if current.length > 1
          current = []
        end
      end
    
      groups << current if current.length > 1
    
      groups
    end

    #
    # => sequential alignment
    #

    def align_hash_rockets_sequential(
      text,
      protected_lines,
      relationship_lines
    )
      lines = text.lines

      groups = collect_sequential_rocket_groups(
        lines,
        protected_lines,
        relationship_lines
      )

      groups.each do |group|
        align_hash_rocket_group!(lines, group)
      end

      lines.join
    end


    #
    # => alignment by structural block + indentation
    #

    def align_hash_rockets_by_indent(
      text,
      protected_lines,
      relationship_lines,
      block_ids
    )
      lines = text.lines

      groups = collect_rocket_groups_by_indent(
        lines,
        protected_lines,
        relationship_lines,
        block_ids
      )

      groups.each do |group|
        align_hash_rocket_group!(lines, group)
      end

      lines.join
    end

    def collect_rocket_groups_by_indent(
      lines,
      protected_lines,
      relationship_lines,
      block_ids
    )
      groups = Hash.new { |hash, key| hash[key] = [] }

      lines.each_with_index do |line, index|
        line_number = index + 1

        next unless hash_rocket_candidate?(
          line,
          line_number,
          protected_lines,
          relationship_lines
        )

        #
        # Important:
        #
        #   $x = { foo => 1, bar => 2 }
        #
        # does NOT participate in alignment-by-indent.
        #
        # normalize-rockets may still normalize it.
        #
        if inline_structural_rocket_line?(line) &&
           !align_rockets_oneline
          next
        end

        indent = leading_indent_width(line)
        block_id = block_ids[line_number]

        groups[[block_id, indent]] << index
      end

      groups.values.select { |group| group.length > 1 }
    end

    #
    # A complete {... => ...} construct on one physical line.
    #
    # This only controls alignment.
    # It does NOT suppress normalize-rockets.
    #
    def inline_structural_rocket_line?(line)
      return false unless line.include?('=>')

      open_pos = line.index('{')
      return false unless open_pos

      close_pos = line.rindex('}')
      return false unless close_pos

      rocket_pos = line.index('=>')
      return false unless rocket_pos

      open_pos < rocket_pos &&
        rocket_pos < close_pos
    end

    def hash_rocket_candidate?(
      line,
      line_number,
      protected_lines,
      relationship_lines
    )
      return false if protected_lines[line_number]
      return false if relationship_lines[line_number]
      return false if line.strip.empty?

      stripped = line.lstrip

      return false if stripped.start_with?(
        '#',
        '//',
        '/*',
        '*'
      )

      return false if stripped.start_with?(
        '->',
        '~>'
      )

      line.include?('=>')
    end

    def align_hash_rocket_group!(lines, indexes)
      parsed = indexes.map do |index|
        split_hash_rocket_line(lines[index])
      end

      return if parsed.any?(&:nil?)

      max_left_width =
        parsed
        .map { |entry| entry[:left].length }
        .max

      indexes.zip(parsed).each do |index, entry|
        padding =
          ' ' * (
            max_left_width -
            entry[:left].length +
            1
          )

        lines[index] =
          entry[:indent] +
          entry[:left] +
          padding +
          '=>' +
          (entry[:right].empty? ? '' : ' ') +
          entry[:right] +
          entry[:newline]
      end
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
    
    def token_offset(token, line_offsets)
      line_offsets.fetch(token.line - 1) + token.column - 1 
    end

    def split_hash_rocket_line(line)
      newline = newline_for(line)
      body = line.sub(/\r?\n\z/, '')



      indent = body[/\A[ \t]*/]
      content = body[indent.length..]

      position = find_unquoted_operator(
        content,
        '=>'
      )

      return nil unless position

      left = content[0...position].rstrip
      right = content[(position + 2)..].lstrip

      return nil if left.empty?

      {
        indent: indent,
        left: left,
        right: right,
        newline: newline,
      }
    end

    #
    # Assignment normalization
    #
    # Only plain variable assignment:
    #
    #   $foo    =bar
    #
    # becomes:
    #
    #   $foo = bar
    #
    # Does not touch ==, =~, !=, <=, >=, etc.
    #
    def normalize_assignment_spacing(
      text,
      protected_lines
    )
      lines = text.lines

      lines.each_with_index.map do |line, index|
        line_number = index + 1

        next line if protected_lines[line_number]

        parsed = split_assignment_line(line)
        next line unless parsed

        parsed[:indent] +
          parsed[:left] +
          ' = ' +
          parsed[:right] +
          parsed[:newline]
      end.join
    end

    #
    # Sequential assignment alignment
    #
    # Only consecutive variable assignment lines.
    #
    def align_assignments_sequential_pass(
      text,
      protected_lines
    )
      lines = text.lines
      groups = []
      current = []

      lines.each_with_index do |line, index|
        line_number = index + 1

        parsed =
          unless protected_lines[line_number]
            split_assignment_line(line)
          end

        if parsed
          indent = parsed[:indent].length

          if current.empty?
            current << index
          elsif assignment_indent(
            lines[current.last]
          ) == indent
            current << index
          else
            groups << current if current.length > 1
            current = [index]
          end
        else
          groups << current if current.length > 1
          current = []
        end
      end

      groups << current if current.length > 1

      groups.each do |group|
        align_assignment_group!(lines, group)
      end

      lines.join
    end

    def assignment_indent(line)
      parsed = split_assignment_line(line)

      parsed ? parsed[:indent].length : -1
    end

    def align_assignment_group!(lines, indexes)
      parsed = indexes.map do |index|
        split_assignment_line(lines[index])
      end

      return if parsed.any?(&:nil?)

      max_left_width =
        parsed
        .map { |entry| entry[:left].length }
        .max

      indexes.zip(parsed).each do |index, entry|
        padding =
          ' ' * (
            max_left_width -
            entry[:left].length +
            1
          )

        lines[index] =
          entry[:indent] +
          entry[:left] +
          padding +
          '= ' +
          entry[:right] +
          entry[:newline]
      end
    end

    def split_assignment_line(line)
      newline = newline_for(line)
      body = line.sub(/\r?\n\z/, '')

      indent = body[/\A[ \t]*/]
      content = body[indent.length..]

      match = content.match(
        /\A(\$[A-Za-z_][A-Za-z0-9_:]*)\s*=(?!=|~)\s*(.*)\z/
      )

      return nil unless match

      {
        indent: indent,
        left: match[1],
        right: match[2],
        newline: newline,
      }
    end

    #
    # Helpers
    #

    def leading_indent_width(line)
      line[/\A[ \t]*/].length
    end

    def newline_for(line)
      if line.end_with?("\r\n")
        "\r\n"
      elsif line.end_with?("\n")
        "\n"
      else
        ''
      end
    end

    #
    # Finds an operator outside quoted strings.
    #
    def find_unquoted_operator(text, operator)
      quoted = false
      quote_char = nil
      escaped = false
      index = 0

      while index < text.length
        char = text[index]

        if quoted
          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == quote_char
            quoted = false
            quote_char = nil
          end

          index += 1
          next
        end

        if char == "'" || char == '"'
          quoted = true
          quote_char = char
          index += 1
          next
        end

        return index if text[index, operator.length] == operator

        index += 1
      end

      nil
    end

    #
    # Splits source into quoted and non-quoted portions.
    #
    # Example:
    #
    #   foo=>bar, 'x => y'
    #
    # yields independent segments so => inside the string isn't changed.
    #
    def split_quoted_segments(text)
      result = []
      current = +''
      quoted = false
      quote_char = nil
      escaped = false

      text.each_char do |char|
        if quoted
          current << char

          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == quote_char
            result << {
              quoted: true,
              text: current,
            }

            current = +''
            quoted = false
            quote_char = nil
          end

          next
        end

        if char == "'" || char == '"'
          unless current.empty?
            result << {
              quoted: false,
              text: current,
            }
          end

          current = +char
          quoted = true
          quote_char = char
        else
          current << char
        end
      end

      unless current.empty?
        result << {
          quoted: quoted,
          text: current,
        }
      end

      result
    end
  end
end
