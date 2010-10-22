require 'ore/config'
require 'ore/template_dir'
require 'ore/interpolations'

require 'thor/group'
require 'date'
require 'set'

module Ore
  class Generator < Thor::Group

    include Thor::Actions
    include Interpolations

    # The base template for all RubyGems
    BASE_TEMPLATE = :base

    #
    # The templates registered with the generator.
    #
    def Generator.templates
      @templates ||= {}
    end

    #
    # Registers a template with the generator.
    #
    # @param [String] path
    #   The path to the template.
    #
    # @raise [StandardError]
    #   The given path was not a directory.
    #
    def Generator.register_template(path)
      unless File.directory?(path)
        raise(StandardError,"#{path.dump} is must be a directory")
      end

      name = File.basename(path).to_sym
      Generator.templates[name] = path
    end

    Config.builtin_templates { |path| Generator.register_template(path) }
    Config.installed_templates { |path| Generator.register_template(path) }

    class_option :markdown, :type => :boolean, :default => false
    class_option :textile, :type => :boolean, :default => false
    class_option :templates, :type => :array,
                             :default => [],
                             :aliases => '-T'
    class_option :name, :type => :string, :aliases => '-n'
    class_option :version, :type => :string,
                            :default => '0.1.0',
                            :aliases => '-V'
    class_option :summary, :default => 'TODO: Summary',
                           :aliases => '-s'
    class_option :description, :default => 'TODO: Description',
                               :aliases => '-D'
    class_option :homepage, :type => :string, :aliases => '-U'
    class_option :email, :type => :string, :aliases => '-e'
    class_option :authors, :type => :array,
                           :default => [ENV['USER']], :aliases => '-a'
    class_option :license, :default => 'MIT', :aliases => '-L'
    class_option :rdoc, :type => :boolean, :default => true
    class_option :yard, :type => :boolean, :default => false
    class_option :test_unit, :type => :boolean, :default => false
    class_option :rspec, :type => :boolean, :default => true
    class_option :bundler, :type => :boolean, :default => false
    class_option :jeweler, :type => :boolean, :default => false
    class_option :git, :type => :boolean, :default => true
    argument :path, :required => true

    def generate
      self.destination_root = path

      enable_templates!
      load_templates!
      initialize_variables!

      generate_directories!
      generate_files!

      if options.git?
        in_root do
          unless File.directory?('.git')
            run 'git init'
            run 'git add .'
            run 'git commit -m "Initial commit."'
          end
        end
      end
    end

    protected

    #
    # Enables templates.
    #
    def enable_templates!
      @enabled_templates = [BASE_TEMPLATE]

      @enabled_templates << :bundler if options.bundler?
      @enabled_templates << :jeweler if options.jeweler?
      
      if options.test_unit?
        @enabled_templates << :test_unit
      elsif options.rspec?
        @enabled_templates << :rspec
      end

      if options.rdoc?
        @enabled_templates << :rdoc
      elsif options.yard?
        @enabled_templates << :yard
      end

      options.templates.each do |name|
        name = name.to_sym

        unless @enabled_templates.include?(name)
          @enabled_templates << name
        end
      end
    end

    #
    # Loads the given templates.
    #
    def load_templates!
      @templates = []
      
      @enabled_templates.each do |name|
        unless (template_dir = Generator.templates[name])
          say "Unknown template #{name.dump}", :red
          exit -1
        end

        self.source_paths << template_dir
        @templates << TemplateDir.new(template_dir)
      end
    end

    #
    # Initializes variables for the templates.
    #
    def initialize_variables!
      @project_dir = File.basename(destination_root)
      @name = (options.name || @project_dir)

      @modules = @name.split('-').map do |words|
        words.split('_').map { |word| word.capitalize }.join
      end

      @module_depth = @modules.length

      @namespace = @modules.join('::')
      @namespace_dir = File.join(@name.split('-'))

      @version = options.version
      @summary = options.summary
      @description = options.description
      @email = options.email
      @safe_email = @email.sub('@',' at ') if @email
      @homepage = (options.homepage || "http://rubygems.org/gems/#{@name}")
      @authors = options.authors
      @author = options.authors.first
      @license = options.license

      @markup = if options.yard?
                  if options.markdown?
                    :markdown
                  elsif options.text_tile?
                    :textile
                  else
                    :rdoc
                  end
                else
                  :rdoc
                end

      @date = Date.today
      @year = @date.year
      @month = @date.month
      @day = @date.day
    end

    #
    # Creates directories listed in the template directories.
    #
    def generate_directories!
      generated = Set[]

      @templates.each do |template|
        template.each_directory do |dir|
          unless generated.include?(dir)
            path = interpolate(dir)
            empty_directory path

            generated << dir
          end
        end
      end
    end

    #
    # Copies static files and renders templates in the template directories.
    #
    def generate_files!
      generated = Set[]

      @templates.reverse_each do |template|
        template.each_file(@markup) do |dest,file|
          unless generated.include?(dest)
            path = interpolate(dest)
            copy_file file, path

            generated << dest
          end
        end

        template.each_template(@markup) do |dest,file|
          unless generated.include?(dest)
            path = interpolate(dest)

            @current_template_dir = File.dirname(dest)
            template file, path
            @current_template_dir = nil

            generated << dest
          end
        end
      end
    end

    #
    # Renders all include files with the given name.
    #
    # @param [Symbol] name
    #   The name of the include.
    #
    # @return [String]
    #   The combined result of the rendered include files.
    #
    def includes(name)
      name = name.to_sym
      output_buffer = []

      if @current_template_dir
        context = instance_eval('binding')

        @templates.each do |template|
          if template.includes.has_key?(@current_template_dir)
            path = template.includes[@current_template_dir][name]

            if path
              erb = ERB.new(File.read(path),nil,'-')
              output_buffer << erb.result(context)
            end
          end
        end
      end

      return output_buffer.join($/)
    end

    #
    # Determines if a template was enabled.
    #
    # @return [Boolean]
    #   Specifies whether the template was enabled.
    #
    def enabled?(name)
      @enabled_templates.include?(name.to_sym)
    end

    #
    # Determines if the project will contain RDoc documented.
    #
    # @return [Boolean]
    #   Specifies whether the project will contain RDoc documented.
    #
    def rdoc?
      options.rdoc?
    end

    #
    # Determines if the project will contain YARD documented.
    #
    # @return [Boolean]
    #   Specifies whether the project will contain YARD documentation.
    #
    def yard?
      enabled?(:yard)
    end

    #
    # Determines if the project is using test-unit.
    #
    # @return [Boolean]
    #   Specifies whether the project is using test-unit.
    #
    def test_unit?
      enabled?(:test_unit)
    end

    #
    # Determines if the project is using RSpec.
    #
    # @return [Boolean]
    #   Specifies whether the project is using RSpec.
    #
    def rspec?
      enabled?(:rspec)
    end

    #
    # Determines if the project is using Bundler.
    #
    # @return [Boolean]
    #   Specifies whether the project is using Bundler.
    #
    def bundler?
      enabled?(:bundler)
    end

  end
end