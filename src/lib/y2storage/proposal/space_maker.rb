#!/usr/bin/env ruby
#
# encoding: utf-8

# Copyright (c) [2015] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "fileutils"
require "storage"
require "y2storage/planned"
require "y2storage/partition"
require "y2storage/disk_size"
require "y2storage/free_disk_space"
require "y2storage/proposal/partitions_distribution_calculator"
require "y2storage/proposal/partition_killer"

module Y2Storage
  module Proposal
    # Class to provide free space for creating new partitions - either by
    # reusing existing unpartitioned space, by deleting existing partitions
    # or by resizing an existing Windows partition.
    class SpaceMaker
      include Yast::Logger

      attr_accessor :settings
      attr_reader :original_graph

      # Initialize.
      #
      # @param disk_analyzer [DiskAnalyzer] information about existing partitions
      # @param settings [ProposalSettings] proposal settings
      def initialize(disk_analyzer, settings)
        @disk_analyzer = disk_analyzer
        @settings = settings
        @all_deleted_sids = []
      end

      # Performs all the operations needed to free enough space to accomodate
      # a set of planned partitions and the new physical volumes needed to
      # accomodate the planned LVM logical volumes.
      #
      # @raise [Error] if is not possible to accomodate the planned
      #   partitions and/or the physical volumes
      #
      # @param original_graph [Devicegraph] initial devicegraph
      # @param planned_partitions [Array<Planned::Partition>] set of partitions to make space for
      # @param lvm_helper [Proposal::LvmHelper] contains information about the
      #     planned LVM logical volumes and how to make space for them
      # @return [Hash] a hash with three elements:
      #   devicegraph: [Devicegraph] resulting devicegraph
      #   deleted_partitions: [Array<Partition>] partitions that
      #     were in the original devicegraph but are not in the resulting one
      #   partitions_distribution: [Planned::PartitionsDistribution] proposed
      #     distribution of partitions, including new PVs if necessary
      #
      def provide_space(original_graph, planned_partitions, lvm_helper)
        @original_graph = original_graph
        @dist_calculator = PartitionsDistributionCalculator.new(lvm_helper)

        # update storage ids of reused volumes in planned volumes list
        planned_partitions.select(&:reuse?).each do |part|
          p = @original_graph.find_by_name(part.reuse_name)
          part.reuse_sid = p.sid if p
        end

        # Partitions that should not be deleted
        keep = lvm_helper.partitions_in_vg
        # Let's filter out partitions with some value in #reuse_name
        partitions = planned_partitions.dup
        partitions.select(&:reuse?).each do |part|
          log.info "No need to find a fit for this partition, it will reuse #{part.reuse_name}: #{part}"
          keep << part.reuse_name
          partitions.delete(part)
        end

        # map device names to storage ids, as names may change during space making
        keep = keep.map { |x| @original_graph.find_by_name(x) }.compact.map(&:sid)

        calculate_new_graph(partitions, keep, lvm_helper)

        {
          devicegraph:             new_graph,
          deleted_partitions:      deleted_partitions,
          partitions_distribution: @distribution
        }
      end

      # Deletes all partitions explicitly marked for removal in the proposal
      # settings, i.e. all the partitions belonging to one of the types with
      # delete_mode set to :all.
      #
      # @see #windows_delete_mode
      # @see #linux_delete_mode
      # @see #other_delete_mode
      #
      # @param original_graph [Devicegraph] initial devicegraph
      # @return [Devicegraph] copy of #original_graph without the unwanted
      #   partitions
      def delete_unwanted_partitions(original_graph)
        result = original_graph.dup
        partition_killer = PartitionKiller.new(result, candidate_disk_names)

        [:windows, :linux, :other].each do |type|
          next unless settings.delete_forced?(type)

          log.info("Forcely deleting #{type} partitions")
          deletion_candidate_partitions(result, type).each do |part_sid|
            sids = partition_killer.delete_by_sid(part_sid)
            @all_deleted_sids.concat(sids)
          end
        end

        result
      end

    protected

      attr_reader :disk_analyzer, :dist_calculator

      # New devicegraph calculated by {#provide_space}
      # @return [Devicegraph]
      attr_reader :new_graph

      # Auxiliary killer used to calculate {#new_graph}
      # @return [PartitionKiller]
      attr_reader :new_graph_part_killer

      # Sids of the partitions deleted while calculating {#new_graph}. In other
      # words, partitions that where in the original devicegraph passed to
      # {#provide_space} but that are not longer there in {#new_graph}.
      #
      # @return [Array<Integer>]
      attr_reader :new_graph_deleted_sids

      # Optional disk name to restrict operations to, if nil all disks can be
      # used.
      #
      # The main process (see {#resize_and_delete}) can be executed several
      # times, depending on the disk restrictions of the planned devices. This
      # value is used by the auxiliary methods of {#resize_and_delete} to ensure
      # they operate only in the relevant device for the current execution, if
      # there is such restriction.
      #
      # @return [String, nil]
      attr_reader :disk_name

      # Sorted lists of sids of the partitions that can be deleted during this
      # execution of {#resize_and_delete} (i.e. for the current value of
      # {#disk_name}).
      #
      # Includes three separate lists indexed by type (:linux, :other, :windows),
      # the first partition on every list will be the first of that type to be
      # deleted (if needed, of course).
      #
      # @return [Hash{Symbol => Array<Integer>]
      attr_reader :sorted_candidates

      # Partitions from the original devicegraph that are not present in the
      # result of the last call to #provide_space
      #
      # @return [Array<Partition>]
      def deleted_partitions
        original_graph.partitions.select { |p| @all_deleted_sids.include?(p.sid) }
      end

      # @see #provide_space
      #
      # @param partitions [Array<Planned::Partition>] partitions to make space for
      # @param keep [Array<String>] device names of partitions that should not be deleted
      # @param lvm_helper [Proposal::LvmHelper] contains information about how
      #     to deal with the existing LVM volume groups
      def calculate_new_graph(partitions, keep, lvm_helper)
        @new_graph = original_graph.duplicate
        @new_graph_part_killer = PartitionKiller.new(@new_graph, candidate_disk_names)
        @new_graph_deleted_sids = []

        # To make sure we are not freeing space in useless places first
        # restrict the operations to disks with particular disk
        # requirements.
        #
        # planned_partitions_by_disk() returns all partitions restricted to
        # a certain disk. Most times partitions are free to be created
        # anywhere but sometimes it is known in advance on which disk they
        # should be created.
        #
        # Start by assigning space to them.
        #
        # The result (if successful) is kept in @distribution.
        #
        planned_partitions_by_disk(partitions).each do |disk, parts|
          resize_and_delete(parts, keep, lvm_helper, disk: disk)
        end

        # Doing something similar for #max_start_offset is more difficult and
        # doesn't pay off (#max_start_offset is used just in one case)

        # Now repeat the process with the full set of planned partitions and all the candidate
        # disks.
        #
        # Note that the result of the run above is not lost as already
        # assigned partitions are taken into account.
        #
        resize_and_delete(partitions, keep, lvm_helper)

        @all_deleted_sids.concat(new_graph_deleted_sids)
      end

      # @return [Hash{String => Array<Planned::Partition>}]
      def planned_partitions_by_disk(planned_partitions)
        planned_partitions.each_with_object({}) do |partition, hash|
          if partition.disk
            hash[partition.disk] ||= []
            hash[partition.disk] << partition
          end
        end
      end

      # Checks whether the goal has already being reached
      #
      # If it returns true, it stores in @distribution the PartitionsDistribution
      # that made it possible.
      #
      # @return [Boolean]
      def success?(planned_partitions)
        # Once a distribution has been found we don't have to look for another one.
        if !@distribution
          spaces = free_spaces(new_graph)
          @distribution = dist_calculator.best_distribution(planned_partitions, spaces)
        end
        !!@distribution
      rescue Error => e
        log.info "Exception while trying to distribute partitions: #{e}"
        @distribution = nil
        false
      end

      # Perform all the needed operations to make space for the partitions
      #
      # @param planned_partitions [Array<Planned::Partition>] partitions
      #     to make space for
      # @param keep [Array<String>] device names of partitions that should not
      #     be deleted
      # @param lvm_helper [Proposal::LvmHelper] contains information about how
      #     to deal with the existing LVM volume groups
      # @param disk [String] optional disk name to restrict operations to
      #
      def resize_and_delete(planned_partitions, keep, lvm_helper, disk: nil)
        log.info "Resize and delete. disk: #{disk}, planned partitions:"
        planned_partitions.each do |p|
          log.info "  mount: #{p.mount_point}, disk: #{p.disk}, min: #{p.min}, max: #{p.max}"
        end

        # restart evaluation
        @distribution = nil

        @disk_name = disk
        calculate_sorted_candidates(keep)

        until success?(planned_partitions)
          break unless execute_next_action(planned_partitions, lvm_helper)
        end

        raise Error unless @distribution
      end

      # Performs the next action of {#resize_and_delete}
      #
      # @return [Boolean] true if some operation was performed. False if nothing
      #   else could be done to reach the goal.
      def execute_next_action(planned_partitions, lvm_helper)
        part = next_partition_to_resize
        if part
          target_shrink_size = resizing_size(part, planned_partitions)
          shrink_partition(part, target_shrink_size)
        else
          part_sid = next_partition_to_delete
          if part_sid
            # Strictly speaking, this could lead to deletion of a partition
            # included in the keep array. In practice it doesn't matter because
            # PVs and extended partitions are never marked to be reused as a
            # planned partition.
            sids = new_graph_part_killer.delete_by_sid(part_sid)
            new_graph_deleted_sids.concat(sids)
          else
            wipe = next_disk_to_wipe(lvm_helper)
            return false unless wipe
            remove_content(wipe)
          end
        end

        true
      end

      # Fills up {#sorted_candidates} for the current execution of
      # {#resize_and_delete}
      def calculate_sorted_candidates(keep)
        @sorted_candidates = {}
        [:linux, :other, :windows].each do |type|
          @sorted_candidates[type] =
            if settings.delete_forbidden?(type)
              []
            else
              deletion_candidate_partitions(new_graph, type, disk_name) - keep
            end
        end
      end

      # Plain list of all candidates to be deleted
      #
      # @return [Array<Integer>]
      def all_sorted_candidates
        sorted_candidates[:linux] + sorted_candidates[:other] + sorted_candidates[:windows]
      end

      # Sid of the next partition to be deleted by {#resize_and_delete}
      #
      # @return [Integer]
      def next_partition_to_delete
        result = (all_sorted_candidates - new_graph_deleted_sids).first

        log.info "Next partition to delete: #{result}"
        result
      end

      # Additional space that needs to be freed while resizing a partition in
      # order to reach the goal
      #
      # @return [DiskSize]
      def resizing_size(partition, planned_partitions)
        spaces = free_spaces(new_graph, disk_name)
        dist_calculator.resizing_size(partition, planned_partitions, spaces)
      end

      # List of free spaces in the given devicegraph
      #
      # @param graph [Devicegraph]
      # @param disk [String] optional disk name to restrict result to
      # @return [Array<FreeDiskSpace>]
      def free_spaces(graph, disk = nil)
        disks_for(graph, disk).each_with_object([]) do |d, list|
          list.concat(d.as_not_empty { d.free_spaces })
        end
      end

      # List of candidate disk devices in the given devicegraph
      #
      # @param devicegraph [Devicegraph]
      # @param device_name [String] optional device name to restrict result to
      #
      # @return [Array<Dasd, Disk>]
      def disks_for(devicegraph, device_name = nil)
        filter = device_name ? [device_name] : candidate_disk_names
        devicegraph.blk_devices.select { |d| filter.include?(d.name) }
      end

      # @return [Array<String>]
      def candidate_disk_names
        settings.candidate_devices
      end

      # Next partition to be deleted by {#resize_and_delete}
      #
      # @return [Partition]
      def next_partition_to_resize
        log.info("Looking for Windows partitions to resize")

        return nil unless settings.resize_windows
        part_names = windows_part_names(disk_name)
        return nil if part_names.empty?

        log.info("Evaluating the following Windows partitions: #{part_names}")

        parts_by_disk = partitions_by_disk(part_names)
        remove_linux_disks!(parts_by_disk) unless no_more_linux_or_other?

        sorted_resizables(parts_by_disk.values.flatten).first
      end

      # @see #next_partition_to_resize
      #
      # @return [Boolean]
      def no_more_linux_or_other?
        (sorted_candidates[:linux] + sorted_candidates[:other] - new_graph_deleted_sids).empty?
      end

      # @return [Hash{String => Partition}]
      def partitions_by_disk(part_names)
        partitions = new_graph.partitions.select { |p| part_names.include?(p.name) }
        partitions.each_with_object({}) do |partition, hash|
          disk = partition.partitionable.name
          hash[disk] ||= []
          hash[disk] << partition
        end
      end

      def remove_linux_disks!(parts_by_disk)
        parts_by_disk.each do |disk, _p|
          if linux_in_disk?(disk)
            log.info "Linux partitions in #{disk}, Windows will not be resized"
            parts_by_disk.delete(disk)
          end
        end
      end

      def linux_in_disk?(name)
        linux_part_names(name).any?
      end

      # Sorted list of partitions that can be resized, partitions with more
      # recoverable space appear first in the list
      #
      # @param partitions [Array<Partition>] list of partitions
      # @return [Array<Partition>]
      def sorted_resizables(partitions)
        resizables = partitions.reject { |part| part.recoverable_size.zero? }
        resizables.sort_by(&:recoverable_size).reverse
      end

      # Reduces the size of a partition
      #
      # If possible, it reduces the size of the partition by shrink_size.
      # Otherwise, it reduces the size as much as possible.
      #
      # This method does not take alignment into account.
      #
      # @param partition [Partition]
      # @param shrink_size [DiskSize] size of the space to substract ideally
      def shrink_partition(partition, shrink_size)
        log.info "Shrinking #{partition.name}"
        # Explicitly avoid alignment to keep current behavior (to be reconsidered)
        partition.resize(partition.size - shrink_size, align_type: nil)
      end

      # Partitions of a given type to be deleted. The type can be:
      #
      #  * :windows Partitions with a Windows installation on it
      #  * :linux Partitions that are part of a Linux installation
      #  * :other Any other partition
      #
      # Extended partitions are ignored, they will be deleted by
      # PartitionKiller if needed
      #
      # @param devicegraph [Devicegraph]
      # @param type [Symbol]
      # @param disk [String] optional disk name to restrict operations to
      # @return [Array<Integer>] sids sorted by disk and by position
      #     inside the disk (partitions at the end are presented first)
      def deletion_candidate_partitions(devicegraph, type, disk = nil)
        sids = []
        names = []	# only for logging
        disks_for(devicegraph, disk).each do |dsk|
          partitions = devicegraph.partitions.select { |p| p.partitionable.name == dsk.name }
          partitions.delete_if { |part| part.type.is?(:extended) }
          filter_partitions_by_type!(partitions, type, dsk.name)
          partitions = partitions.sort_by { |part| part.region.start }.reverse
          sids += partitions.map(&:sid)
          names += partitions.map(&:name)
        end

        log.info "Deletion candidates (#{type}): #{names}"
        sids
      end

      def filter_partitions_by_type!(partitions, type, disk)
        case type
        when :windows
          partitions.select! { |part| windows_part_names(disk).include?(part.name) }
        when :linux
          partitions.select! { |part| linux_part_names(disk).include?(part.name) }
        when :other
          partitions.select! do |part|
            !linux_part_names(disk).include?(part.name) &&
              !windows_part_names(disk).include?(part.name)
          end
        end
      end

      # Finds the next device that can be completely cleaned by {#resize_and_delete}.
      #
      # It searchs for disk-like devices not containining a partition table,
      # like disks directly formatted or used as members of an LVM or software RAID.
      #
      # @param lvm_helper [Proposal::LvmHelper] contains information about how
      #     to deal with the existing LVM volume groups
      # @return [BlkDevice]
      def next_disk_to_wipe(lvm_helper)
        log.info "Searching next disk to wipe (disk_name: #{disk_name})"

        disks_for(new_graph, disk_name).each do |disk|
          log.info "Checking if the disk #{disk.name} has a partition table"

          next unless disk.has_children? && disk.partition_table.nil?
          log.info "Found something that is not a partition table"

          if disk.descendants.any? { |dev| lvm_helper.vg_to_reuse?(dev) }
            log.info "Not cleaning up #{disk.name} because its VG must be reused"
            next
          end

          return disk
        end

        nil
      end

      # Remove descendants of a disk and also partitions from other disks that
      # are not longer useful afterwards
      #
      # TODO: delete partitions that were part of the removed VG and/or RAID
      #
      # @param disk [Partitionable] disk-like device to cleanup. It must not be
      #   part of a multipath device or a BIOS RAID.
      def remove_content(disk)
        disk.remove_descendants
      end

      # Device names of windows partitions detected by disk_analyzer
      #
      # @return [array<string>]
      def windows_part_names(disk = nil)
        parts = if disk
          disk_analyzer.windows_partitions(disk)
        else
          disk_analyzer.windows_partitions
        end
        parts.map(&:name)
      end

      # Device names of linux partitions detected by disk_analyzer
      #
      # @return [array<string>]
      def linux_part_names(disk = nil)
        parts = if disk
          disk_analyzer.linux_partitions(disk)
        else
          disk_analyzer.linux_partitions
        end
        parts.map(&:name)
      end
    end
  end
end
