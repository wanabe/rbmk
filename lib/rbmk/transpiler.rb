# frozen_string_literal: true

# rbs_inline: enabled

require "prism"

require "rbmk/node"

module Rbmk
  # The class of transpiler.
  class Transpiler
    # @rbs @reverse_index_offsets: [[Integer, Integer]]
    # @rbs @dst: String

    # @rbs src: String
    # @rbs return: void
    def initialize(src)
      @src = src
    end

    # @rbs return: String
    def transpile
      correct_and_collect
      apply_collected_data
      @dst
    end

    # @rbs return: void
    def correct_and_collect
      @dst = @src.dup
      @mod_data = []

      previous_error_count = 0
      loop do
        src = @dst.dup
        parse_result = Prism.parse(src)
        node = Node.new(parse_result.value)
        parse_errors = parse_result.errors
        @reverse_index_offsets = []
        break if parse_errors.empty?

        parse_errors.each do |parse_error|
          case parse_error.type
          when :argument_formal_ivar
            src_index = parse_error.location.start_offset
            dst_index = dst_index(src_index)
            length = parse_error.location.length

            src.match(/([^@]*)@(\w{#{length - 1}})/, src_index)
            prefix = ::Regexp.last_match(1)
            name = ::Regexp.last_match(2)
            raise Rbmk::Error, "Expected ivar but '#{src[src_index, length]}'" if prefix != "" || !name.is_a?(String)

            @dst[dst_index, length] = name
            insert_offset(dst_index, -1)

            arg_node = node.each.find do |node|
              node.prism_node.location.start_offset == parse_error.location.start_offset && node.parameter_node
            end
            raise Rbmk::Error, "ParameterNode not found" unless arg_node

            name = arg_node.parameter_name[1..]
            arg_node.ancestors.find { _1.prism_node.is_a?(Prism::DefNode) }
            insert_mod_data(dst_index, :ivar_arg, "@#{name} = #{name}")
          end
        end
        if previous_error_count.positive? && previous_error_count <= parse_errors.size
          raise Rbmk::Error, "Syntax error: #{parse_errors.map(&:message).join("\n")}"
        end

        previous_error_count = parse_errors.size
      end
    end

    # @rbs return: void
    def apply_collected_data
      root_node = Node.new(Prism.parse(@dst).value)
      @mod_data.each do |(index, type, modify_script)|
        case type
        when :ivar_arg
          parameter_node = root_node.each.find do |node|
            break if node.prism_node.location.start_offset > index

            node.prism_node.location.start_offset == index && node.parameter_node
          end
          raise Rbmk::Error, "ParameterNode not found" unless parameter_node

          def_node = parameter_node.ancestors.find { _1.prism_node.is_a?(Prism::DefNode) }
          raise Rbmk::Error, "DefNode not found" if !def_node || !def_node.prism_node.is_a?(Prism::DefNode)

          def_body_location = def_node.prism_node.body&.location
          if def_body_location
            indent = def_body_location.start_column
            dst_index = dst_index(def_body_location.start_offset - indent)
          elsif def_node.prism_node.end_keyword_loc
            indent = def_node.prism_node.end_keyword_loc.start_column + 2
            dst_index = dst_index(def_node.prism_node.end_keyword_loc.start_offset - indent + 2)
          else
            raise Rbmk::Error, "Invalid DefNode #{def_node.prism_node.inspect}"
          end

          dst_line = "#{" " * indent}#{modify_script}\n"
          @dst[dst_index, 0] = dst_line
          insert_offset(dst_index + 1, dst_line.size)
        else
          raise Rbmk::Error, "Unexpected type #{type}"
        end
      end
    end

    # @rbs src_index: Integer
    # @rbs return: Integer
    def dst_index(src_index)
      offset = @reverse_index_offsets.find { _1.first <= src_index }&.last || 0
      offset + src_index
    end

    # @rbs new_index: Integer
    # @rbs new_diff: Integer
    # @rbs return: void
    def insert_offset(new_index, new_diff)
      array_index = @reverse_index_offsets.find_index.with_index do |(index, _), i|
        if new_index < index
          @reverse_index_offsets[i][1] += new_diff
          false
        else
          true
        end
      end
      if array_index
        new_diff += @reverse_index_offsets[array_index][1]
      else
        array_index = -1
      end
      @reverse_index_offsets.insert(array_index, [new_index, new_diff])
      @mod_data.each do |line|
        break if line[0] < new_index

        line[0] += new_diff
      end
    end

    # @rbs new_index: Integer
    # @rbs type: Symbol
    # @rbs modify_script: String
    # @rbs return: void
    def insert_mod_data(new_index, type, modify_script)
      array_index = @mod_data.find_index.with_index do |(index, _), _i|
        new_index >= index
      end
      @mod_data.insert(array_index || -1, [new_index, type, modify_script])
    end
  end
end
