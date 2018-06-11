# encoding: utf-8

# Copyright (c) [2017] SUSE LLC
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

require "y2storage/storage_class_wrapper"
require "y2storage/blk_device"
require "y2storage/crypttab"

module Y2Storage
  # An encryption layer on a block device
  #
  # This is a wrapper for Storage::Encryption
  class Encryption < BlkDevice
    wrap_class Storage::Encryption

    # @!method blk_device
    #   Block device directly hosting the encryption layer.
    #
    #   @return [BlkDevice] the block device being encrypted
    storage_forward :blk_device, as: "BlkDevice"

    # @!attribute password
    #   @return [String] the encryption password
    storage_forward :password
    storage_forward :password=

    # @!method self.all(devicegraph)
    #   @param devicegraph [Devicegraph]
    #   @return [Array<Encryption>] all the encryption devices in the given devicegraph
    storage_class_forward :all, as: "Encryption"

    # @!method in_etc_crypttab?
    #   @return [Boolean] whether the device is included in /etc/crypttab
    storage_forward :in_etc_crypttab?

    # The setter is intentionally hidden. See similar comment for Md#in_etc_mdadm
    storage_forward :storage_in_etc_crypttab=, to: :in_etc_crypttab=
    private :storage_in_etc_crypttab=

    class << self
      # DeviceMapper name to use for the encrypted version of the given device.
      #
      # FIXME: with the current implementation (using the device kernel name
      # instead of UUID or something similar), the DeviceMapper for an encrypted
      # /dev/sda5 would be "cr_sda5", which implies a quite high risk of
      # collision with existing DeviceMapper names.
      #
      # Revisit this after improving libstorage-ng capabilities about
      # alternative names and DeviceMapper.
      #
      # @return [String]
      def dm_name_for(device)
        "cr_#{device.basename}"
      end

      # Updates encryption names according to the values indicated in a crypttab file
      #
      # For each entry in the crypttab file, it finds the corresponding device and updates
      # its encryption name with the value indicated in its crypttab entry. The device is
      # not modified at all if it is not encrypted.
      #
      # @param devicegraph [Devicegraph]
      # @param crypttab_path [String] path to a crypttab file
      def use_crypttab_names(devicegraph, crypttab_path)
        crypttab = Crypttab.new(crypttab_path)

        assign_crypttab_names(devicegraph, crypttab)
      end

    private

      # Sets the crypttab names according to the values indicated in a crypttab file
      #
      # @param devicegraph [Devicegraph]
      # @param crypttab [Crypttab]
      def assign_crypttab_names(devicegraph, crypttab)
        crypttab.entries.each { |e| assign_crypttab_name(devicegraph, e) }
      end

      # Sets the crypttab name according to the value indicated in a crypttab entry
      #
      # @param devicegraph [Devicegraph]
      # @param entry [SimpleEtcCrypttabEntry]
      def assign_crypttab_name(devicegraph, entry)
        device = entry.find_device(devicegraph)
        return unless device && device.encrypted?

        device.encryption.dm_table_name = entry.name
      end
    end

    # @see BlkDevice#plain_device
    def plain_device
      blk_device
    end

    # @see Device#in_etc?
    # @see #in_etc_crypttab?
    def in_etc?
      in_etc_crypttab?
    end

  protected

    def types_for_is
      super << :encryption
    end

    # @see Device#update_etc_attributes
    def assign_etc_attribute(value)
      self.storage_in_etc_crypttab = value
    end
  end
end
