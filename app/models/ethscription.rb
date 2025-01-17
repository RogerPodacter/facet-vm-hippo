class Ethscription < ApplicationRecord
  include ContractErrors
  
  belongs_to :eth_block, foreign_key: :block_number, primary_key: :block_number, touch: true, optional: true
  
  has_many :contracts, primary_key: 'transaction_hash', foreign_key: 'transaction_hash'
  has_one :transaction_receipt, primary_key: 'transaction_hash', foreign_key: 'transaction_hash'
  has_one :contract_transaction, primary_key: 'transaction_hash', foreign_key: 'transaction_hash'
  has_one :system_config_version, primary_key: 'transaction_hash', foreign_key: 'transaction_hash'
  has_many :contract_states, primary_key: 'transaction_hash', foreign_key: 'transaction_hash'

  before_validation :downcase_hex_fields
  
  scope :newest_first, -> { order(block_number: :desc, transaction_index: :desc) }
  scope :oldest_first, -> { order(block_number: :asc, transaction_index: :asc) }
  
  scope :unprocessed, -> { where(processing_state: "pending") }
  
  def content
    content_uri[/.*?,(.*)/, 1]
  end
  
  def parsed_content
    JSON.parse(content)
  end
  
  def processed?
    processing_state != "pending"
  end
  
  def process!(persist:)
    Ethscription.transaction do
      if processed?
        raise "Ethscription already processed: #{inspect}"
      end
      
      begin
        unless initial_owner == ("0x" + "0" * 40)
          raise InvalidEthscriptionError.new("Invalid initial owner: #{initial_owner}")
        end
        
        if mimetype == ContractTransaction.transaction_mimetype
          tx = ContractTransaction.create_from_ethscription!(self, persist: persist)
          
          assign_attributes(contract_transaction: tx)
        elsif mimetype == SystemConfigVersion.system_mimetype
          version = SystemConfigVersion.create_from_ethscription!(self, persist: persist)
          
          assign_attributes(system_config_version: version)
        else
          raise InvalidEthscriptionError.new("Unexpected mimetype: #{mimetype}")
        end
        
        assign_attributes(
          processing_state: "success",
        )
      rescue InvalidEthscriptionError => e
        assign_attributes(
          processing_state: "failure",
          processing_error: e.message
        )
      end
      
      assign_attributes(processed_at: Time.current)
      
      save! if persist
      self
    end
  end
  
  private
  
  def downcase_hex_fields
    self.transaction_hash = transaction_hash.downcase
    self.creator = creator.downcase
    self.initial_owner = initial_owner.downcase
  end
end