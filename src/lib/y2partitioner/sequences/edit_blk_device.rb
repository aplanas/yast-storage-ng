require "yast"
require "ui/sequence"
require "y2partitioner/device_graphs"
require "y2partitioner/dialogs"

Yast.import "Popup"
Yast.import "Wizard"

module Y2Partitioner
  module Sequences
    # BlkDevice edition
    class EditBlkDevice < UI::Sequence
      include Yast::Logger

      # @param blk_device [Y2Storage::BlkDevice]
      def initialize(blk_device)
        textdomain "storage"
        @blk_device = blk_device
        @fs_controller = FilesystemController.new(blk_device, title)
      end

      def run
        sequence_hash = {
          "ws_start"       => "preconditions",
          "preconditions"  => { next: "format_options" },
          "format_options" => { next: "password" },
          "password"       => { next: "commit" },
          "commit"         => { finish: :finish }
        }

        sym = nil
        DeviceGraphs.instance.transaction do
          sym = wizard_next_back do
            super(sequence: sequence_hash)
          end
          sym == :finish
        end

        sym
      end

      # FIXME: move to Wizard
      def wizard_next_back(&block)
        Yast::Wizard.OpenNextBackDialog
        block.call
      ensure
        Yast::Wizard.CloseDialog
      end

      def preconditions
        if blk_device.is?(:partition) && blk_device.type.is?(:extended)
          Yast::Popup.Error(_("An extended partition cannot be edited"))
          :back
        else
          :next
        end
      end
      skip_stack :preconditions

      def format_options
        Dialogs::FormatAndMount.run(fs_controller)
      end

      def password
        return :next unless fs_controller.to_be_encrypted?
        Dialogs::EncryptPassword.run(fs_controller)
      end

      def commit
        fs_controller.finish
        :finish
      end

    private

      attr_reader :fs_controller, :blk_device

      def title
        if blk_device.is?(:md)
          # TRANSLATORS: dialog title. %s is a device name like /dev/md0
          _("Edit RAID %s") % blk_device.name
        elsif blk_device.is?(:lvm_lv)
          msg_args = { lv_name: blk_device.lv_name, vg: blk_device.lvm_vg.name }
          # TRANSLATORS: dialog title. %{lv_name} is an LVM LV name (e.g.'root'),
          # %{vg} is the device name of an LVM VG (e.g. '/dev/system').
          _("Edit Logical Volume %{lv_name} on %{vg}") % msg_args
        else
          # TRANSLATORS: dialog title. %s is a device name like /dev/sda1
          _("Edit Partition %s") % blk_device.name
        end
      end
    end
  end
end
