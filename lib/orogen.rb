# frozen_string_literal: true

begin
    require "typelib"
rescue LoadError
    warn "Cannot require 'typelib'"
    warn "If you are using Rock, the 'typelib' package should have been installed automatically."
    warn "First, make sure that you have loaded autoproj's env.sh script before continuing"
    warn "Second, typelib should be installed in tools/typelib from the root of your Rock installation."
    warn "If it is not the case, report this to the rock developers. To workaround, run"
    warn "  amake typelib"
    warn "and try again."
    exit 1
end

require "utilrb/logger"

module OroGen
    OROGEN_LIB_DIR = File.expand_path("orogen", File.dirname(__FILE__))
    extend Logger::Root("OroGen", Logger::WARN)

    module Spec
    end

    module Gen
        module RTT_CPP
        end
    end

    # Code-generation support for the different supported RTT transports
    module TypekitMarshallers
        extend Logger::Hierarchy
    end
end

module Orocos
    Spec = OroGen::Spec
    Generation = OroGen::Gen::RTT_CPP
    TypekitMarshallers = OroGen::TypekitMarshallers
end

require "utilrb/pkgconfig"
require "metaruby/dsls/doc"
require "orogen/typenames"
require "rexml/streamlistener"
require "rexml/document"

require "orogen/version"
require "orogen/warn_deprecated"
require "orogen/exceptions"
require "orogen/base"
require "orogen/check_for_stray_dots"
require "orogen/plugins"
require "orogen/loaders"
require "orogen/spec"

OroGen.load_orogen_plugins unless ENV["OROGEN_DISABLE_PLUGINS"] == "1"
