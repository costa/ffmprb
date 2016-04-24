module Ffmprb

  class Process

    class Output

      class Transition

        attr_reader :length

        def initialize(**opts)

          @length = opts.delete(:blend)
          fail Error, "Unsupported (yet) transition, sorry."  unless @length

          Util.assert_options_empty! opts
        end

      end

    end

  end

end
