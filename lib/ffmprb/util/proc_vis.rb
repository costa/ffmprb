require 'set'
require 'monitor'

module Ffmprb

  module Util

    module ProcVis

      UPDATE_PERIOD_SEC = 1

      module Node

        attr_accessor :_proc_vis

        def proc_vis_name
          lbl = respond_to?(:label) && label ||
            short_name ||
            to_s
          # ).gsub(/\W+/, '_').sub(/^[^[:alpha:]]*/, '')
          "#{object_id} [labelType=\"html\" label=#{lbl.to_json}]"
        end

        def proc_vis_node(node, op=:upsert)
          _proc_vis.proc_vis_node node, op  if _proc_vis
        end

        def proc_vis_edge(from, to, op=:upsert)
          _proc_vis.proc_vis_edge from, to, op  if _proc_vis
        end

        private

        def short_name
          return  unless respond_to? :name

          short =
            if name.length <= 30
              name
            else
              "#{name[0..13]}..#{name[-14..-1]}"
            end
          "#{self.class.name.split('::').last}: #{short}"
        end

      end

      module ClassMethods

        attr_accessor :proc_vis_firebase

        def proc_vis_node(obj, op=:upsert)
          return  unless proc_vis_init?
          fail Error, "Must be a #{Node.name}"  unless obj.kind_of? Node  # XXX duck typing FTW

          obj._proc_vis = self
          obj.proc_vis_name.tap do |lbl|
            proc_vis_sync do
              @_proc_vis_nodes ||= {}
              if op == :remove
                @_proc_vis_nodes.delete obj
              else
                @_proc_vis_nodes[obj] = lbl
              end
            end
            proc_vis_update  # XXX optimise
          end
        end

        def proc_vis_edge(from, to, op=:upsert)
          return  unless proc_vis_init?

          if op == :upsert
            proc_vis_node from
            proc_vis_node to
          end
          "#{from.object_id} -> #{to.object_id}".tap do |edge|
            proc_vis_sync do
              @_proc_vis_edges ||= SortedSet.new
              if op == :remove
                @_proc_vis_edges.delete edge
              else
                @_proc_vis_edges << edge
              end
            end
            proc_vis_update
          end
        end

        private

        def proc_vis_update
          @_proc_vis_upq.enq 1
        end


        def proc_vis_do_update
          nodes = @_proc_vis_nodes.map{ |_, node| "#{node};"}.join("\n")  if @_proc_vis_nodes
          edges = @_proc_vis_edges.map{ |edge| "#{edge};"}.join("\n")  if @_proc_vis_edges
          proc_vis_firebase_client.set proc_vis_pid, dot: [*nodes, *edges].join("\n")
        end

        def proc_vis_pid
          @proc_vis_pid ||= object_id.tap do |pid|
            Ffmprb.logger.info "You may view your process visualised at: https://#{proc_vis_firebase}.firebaseapp.com/?pid=#{pid}"
          end
        end

        def proc_vis_init?
          !!proc_vis_firebase_client
        end

        def proc_vis_up_init
          @_proc_vis_thr ||= Thread.new do  # NOTE update throttling
            prev_t = Time.now
            while @_proc_vis_upq.deq  # NOTE currently, runs forever (nil terminator needed)
              proc_vis_do_update
              Thread.current.live!  # XXX not the best we can do here
              while Time.now - prev_t < UPDATE_PERIOD_SEC
                @_proc_vis_upq.deq  # NOTE drains the queue
              end
              @_proc_vis_upq.enq 1
            end
          end
        end

        def proc_vis_sync_init
          @_proc_vis_mon ||= Monitor.new
          @_proc_vis_upq ||= Queue.new
        end
        def proc_vis_sync(&blk)
          @_proc_vis_mon.synchronize &blk  if blk
        end

        def proc_vis_firebase_client
          return @proc_vis_firebase_client  if defined? @proc_vis_firebase_client
          @proc_vis_firebase_client =
            if proc_vis_firebase
              url = "https://#{proc_vis_firebase}.firebaseio.com/proc/"
              Ffmprb.logger.debug{"Connecting to #{url}"}
              begin
                Firebase::Client.new(url).tap do
                  Ffmprb.logger.info "Connected to #{url}"
                  proc_vis_up_init
                end
              rescue
                Ffmprb.logger.error "Could not connect to #{url}"
              end
            end
        end

      end

      def self.included(klass)
        klass.extend ClassMethods
        klass.send :proc_vis_sync_init
      end


    end

  end

end
