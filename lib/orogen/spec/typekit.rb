# frozen_string_literal: true

module OroGen
    module Spec
        # A typekit, i.e. a subpart of the system that handles a set of types
        #
        # Typekits provide (at model time) definitions of types, and (at
        # runtime) the support to marshal/unmarshal them on transports
        class Typekit
            attr_reader :loader, :name, :registry, :typelist, :interface_typelist,
                        :opaques, :opaque_registry, :imported_typekits

            attr_predicate :define_dummy_types?, true

            attr_predicate :virtual?, true

            def self.parse_typelist(typelist_txt)
                raw_typelist = typelist_txt.split("\n").map(&:strip)
                typekit_typelist = []
                typekit_interface_typelist = []
                raw_typelist.each do |decl|
                    # using non greedy kleene star to match first expression: .*?
                    # to handle following patterns:
                    # /string
                    # /unsigned char[8]
                    # /unsigned char[8] 0
                    if decl =~ /^(.*) (\d)$/
                        type = ::Regexp.last_match(1)
                        is_interface = (::Regexp.last_match(2) == "1")
                    else
                        type = decl
                        is_interface = true
                    end

                    typekit_typelist << type
                    typekit_interface_typelist << type if is_interface
                end
                [typekit_typelist, typekit_interface_typelist]
            end

            class OpaqueInfoListener
                include REXML::StreamListener
                attr_reader :registry, :typekit_registry, :opaques

                def initialize(typekit_registry)
                    @registry = Typelib::Registry.new
                    @typekit_registry = typekit_registry
                    @opaques = []
                end

                def tag_start(name, attributes)
                    return if name != "opaque"

                    base_type_name  = attributes["name"]
                    inter_type_name = attributes["marshal_as"]
                    includes        = attributes["includes"]
                    needs_copy      = attributes["needs_copy"]
                    opaques << OpaqueDefinition.new(
                        typekit_registry.get(base_type_name),
                        inter_type_name,
                        Hash[include: includes.split(":"),
                             needs_copy: (needs_copy == "1")],
                        nil
                    )
                    registry.merge(typekit_registry.minimal(base_type_name))
                end
            end

            def self.from_raw_data(loader, name, registry_xml, typelist_txt)
                typekit_registry = Typelib::Registry.new
                Typelib::Registry.add_standard_cxx_types(typekit_registry)
                typekit_registry.merge_xml(registry_xml)

                typekit_typelist, typekit_interface_typelist = parse_typelist(typelist_txt)
                typekit = new(loader, name,
                              typekit_registry,
                              typekit_typelist,
                              typekit_interface_typelist)

                listener = OpaqueInfoListener.new(typekit_registry)
                REXML::Document.parse_stream(registry_xml, listener)
                typekit.opaques.concat(listener.opaques)
                typekit.opaque_registry.merge(listener.registry)

                typekit
            end

            def initialize(loader, name, registry = Typelib::Registry.new, typelist = [],
                interface_typelist = [])
                @loader = loader
                @name = name
                @registry = registry
                @typelist = typelist.to_set
                @interface_typelist = interface_typelist.to_set
                @opaques = []
                @opaque_registry = Typelib::Registry.new
                @imported_typekits = Set.new
            end

            def has_opaques?
                if @has_opaques.nil?
                    @has_opaques = registry.any? { |t| includes?(t) && t.opaque? }
                end
                @has_opaques
            end

            def self_types
                typelist.map { |name| registry.get(name) }
            end

            def defines_array_of?(type)
                typename = if type.respond_to?(:name) then type.name
                           else
                               type.to_str
                           end

                typelist.any? { |str| str =~ /#{Regexp.quote(typename)}(\[\d+\])+/ }
            end

            # @deprecated use {#include?} instead
            def includes?(type)
                include?(type)
            end

            def include?(type)
                typename = if type.respond_to?(:name) then type.name
                           else
                               type.to_str
                           end
                typelist.include?(typename)
            end

            def interface_type?(type)
                typename = if type.respond_to?(:name) then type.name
                           else
                               type.to_str
                           end
                interface_typelist.include?(typename)
            end

            # Get the opaque definition for a given type
            #
            # @param [Type,String] the type or type name
            # @return [OpaqueDefinition]
            def opaque_specification(type_def)
                type = resolve_type(type_def)
                raise "#{type} is unknown" unless type
                raise "#{type} is not opaque" unless type.opaque?

                if (result = opaques.find { |opaque_def| opaque_def.type.eql? type })
                    result
                else
                    raise InternalError,
                          "#{self}#opaque_specification called for type #{type.name}, but could not find the corresponding opaque specification"
                end
            end

            # Finds the opaque (or opaque-containing) type for which the given
            # type is an intermediate
            #
            # @return [Type,nil] the type, or nil if 'type' is not used as an
            #   intermediate
            def find_opaque_for_intermediate(type)
                type = resolve_type(type.name)
                if m_type?(type)
                    # Yuk
                    begin
                        if @intermediate_to_opaque && (result = @intermediate_to_opaque[type.name])
                            result
                        elsif type.name =~ /_m$/
                            resolve_type(type.name.gsub(/_m$/, ""))
                        else
                            raise Typelib::NotFound
                        end
                    rescue Typelib::NotFound
                        # This is a pretty expensive operation and is seldom
                        # needed, so avoid doing it unnecessarily
                        @intermediate_to_opaque ||= {}
                        @indexed_intermediates ||= Set.new
                        registry.each do |t|
                            if !@indexed_intermediates.include?(t) && t.contains_opaques?
                                @indexed_intermediates << t
                                @intermediate_to_opaque[intermediate_type_name_for(t)] = t
                            end
                        end
                        @intermediate_to_opaque[type.name]
                    end
                elsif type <= Typelib::ContainerType
                    if (opaque_deference = find_opaque_for_intermediate(type.deference))
                        resolve_type("#{type.container_kind}<#{opaque_deference.name}>")
                    end
                elsif (opaque_def = opaques.find do |spec|
                    resolve_type(spec.intermediate).eql?(type)
                end)
                    opaque_def.type
                end
            end

            # Computes the name of the type that should be used as an
            # intermediate for the given type
            #
            # @param [String,Type] type_def the type or type name
            # @param [Boolean] is_normalized if true, the provided type name is
            #   supposed to be normalized. Otherwise, an (expensive) normalization
            #   will be computed if it cannot be found as-is in the typekit's
            #   registry
            # @return [String] the normalized name of the intermediate type, or
            #   the type's name if 'type' is not an opaque
            def intermediate_type_name_for(type_def)
                type = resolve_type(type_def)
                if type.opaque?
                    opaque_specification(type_def).intermediate
                elsif type.contains_opaques?
                    if type < Typelib::ArrayType
                        "#{intermediate_type_name_for(type.deference)}[#{type.length}]"
                    elsif type < Typelib::ContainerType
                        "#{type.container_kind}<#{intermediate_type_name_for(type.deference)}>"
                    else
                        path = Typelib.split_typename(type.name)
                        path.map! do |p|
                            p.gsub(%r{[<>\[\], /]}, "_")
                        end
                        "/" + path.join("/") + "_m"
                    end
                else
                    type.name
                end
            end

            # Returns a matching type in {#registry}
            #
            # @param [#name,String] type
            # @return [Model<Typelib::Type>]
            # @raise Typelib::NotFound
            def resolve_type(type)
                type = type.name if type.respond_to?(:name)
                registry.get(type)
            end

            # Gets the intermediate type for a given type
            #
            # @param [Type,String] type_def the type or type name
            # @return [Type] the type of the intermediate, or 'type_def' itself
            #   if 'type_def' is not an opaque
            # @raise Typelib::NotFound if the expected intermediate type cannot
            #   be found
            def intermediate_type_for(type_def)
                typename = intermediate_type_name_for(type_def)
                resolve_type(typename)
            end

            # Gets the opaque type for a given type
            #
            # @param [#name,String] type the type or type name
            # @return [Model<Typelib::Type>] the type of the opaque, or the
            #   given type if it is not an intermediate type
            # @raise Typelib::NotFound if the expected intermediate type cannot
            #   be found
            def opaque_type_for(type)
                find_opaque_for_intermediate(type) || resolve_type(type)
            end

            # Checks if a type is used as an intermediate
            def intermediate_type?(type)
                !!find_opaque_for_intermediate(type)
            end

            # Checks if a type is an oroGen-generated type used as an
            # intermediate
            def m_type?(type)
                return true if type.name =~ /_m$/

                if type.respond_to?(:deference)
                    type = type.deference while type.respond_to?(:deference)
                    m_type?(type)
                else
                    false
                end
            end

            def to_s
                "#<OroGen::Spec::Typekit #{name}>"
            end

            def inspect
                "#<OroGen::Spec::Typekit #{name}>"
            end

            def respond_to_missing?(m, include_private = false)
                if super then super
                elsif m.to_s =~ /^create_(interface_)?(\w+)$/
                    registry.respond_to?("create_#{::Regexp.last_match(2)}")
                end
            end

            # Adds to the API of self the create_* methods on Typelib::Registry.
            # All create_ methods are available, as well as the corresponding
            # create_interface_XXX which both creates the type and declares it
            # as a valid interface type
            #
            # @example create a null type
            #   typekit.create_interface_null('/NewType')
            def method_missing(m, *args, &block)
                case m.to_s
                when /^create_(interface_)?(\w+)$/
                    interface = !!::Regexp.last_match(1)
                    category  = ::Regexp.last_match(2)
                    type = registry.send("create_#{category}", *args, &block)
                    typelist << type.name
                    interface_typelist << type.name if interface
                    type
                else super
                end
            end
        end
    end
end
