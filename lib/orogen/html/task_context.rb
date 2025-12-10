# frozen_string_literal: true

module OroGen
    module HTML
        class TaskContext
            attr_reader :page, :task, :template

            def initialize(page)
                path = File.join(File.dirname(__FILE__), "task_context_fragment.page")
                @template = ERB.new(File.read(path))
                @template.filename = path
                @page = page
            end

            def render(task, options = {})
                options, push_options = Kernel.filter_options options, doc: true,
                                                                       external_objects: nil
                @task = task
                page.push nil, page.main_doc(task.doc) if options[:doc] && task.doc
                page.push(nil, template.result(binding), push_options)
            end
        end
    end
end
