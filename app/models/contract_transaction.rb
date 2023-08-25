class ContractTransaction
  include ContractErrors
  
  attr_accessor :contract_id, :function_name, :contract_protocol,
  :function_args, :tx, :call_receipt, :ethscription, :operation
  
  class Tx
    attr_reader :origin
    
    def origin=(address)
      @origin = TypedVariable.create(:address, address).value
    end
  end
  
  def tx
    @tx ||= Tx.new
  end
  
  def set_operation_from_ethscription
    return unless ethscription.initial_owner == "0x" + "0" * 40
    
    mimetype = ethscription.mimetype
    match_data = mimetype.match(%q{application/vnd.esc.contract.(call|deploy)\+json})

    self.operation = match_data && match_data[1].to_sym
  end
  
  def self.create_and_execute_from_ethscription_if_needed(ethscription)
    new.import_from_ethscription(ethscription)&.execute_transaction
  end
  
  def self.make_static_call(contract_id:, function_name:, function_args: {}, msgSender: nil)
    new(
      operation: :static_call,
      function_name: function_name,
      function_args: function_args,
      contract_id: contract_id,
      msgSender: msgSender
    ).execute_static_call.as_json
  end
  
  def initialize(options = {})
    @operation = options[:operation]
    @function_name = options[:function_name]
    @function_args = options[:function_args]
    @contract_id = options[:contract_id]
    tx.origin = options[:msgSender]
  end
  
  def import_from_ethscription(ethscription)
    self.ethscription = ethscription
    set_operation_from_ethscription
    
    return unless operation.present?
    
    self.call_receipt = ContractCallReceipt.new(
      caller: ethscription.creator,
      ethscription_id: ethscription.ethscription_id,
      timestamp: ethscription.creation_timestamp
    )
    
    begin
      data = JSON.parse(ethscription.content)
    rescue JSON::ParserError => e
      return call_receipt.update!(
        error_message: "JSON::ParserError: #{e.message}"
      )
    end
    
    self.function_name = is_deploy? ? :constructor : data['functionName']
    self.function_args = data['args'] || data['constructorArgs'] || {}
    self.contract_id = data['contractId']
    self.contract_protocol = data['protocol']
    
    call_receipt.tap do |r|
      r.caller = ethscription.creator
      r.ethscription_id = ethscription.ethscription_id
      r.timestamp = ethscription.creation_timestamp
      r.function_name = function_name
      r.function_args = function_args
    end
    
    tx.origin = ethscription.creator
    
    self
  end
  
  def create_execution_context_for_call(callee_contract_id, caller_address_or_id)
    callee_contract = Contract.find_by_contract_id(callee_contract_id.to_s)
    
    if callee_contract.blank?
      raise TransactionError.new("Contract not found: #{callee_contract_id}")
    end
    
    callee_contract.msg.sender = caller_address_or_id
    callee_contract.current_transaction = self
    
    ContractProxy.new(callee_contract, operation: operation)
  end
  
  def ensure_valid_deploy!
    return unless is_deploy? && contract_id.blank?
    
    unless self.class.valid_contract_types.include?(contract_protocol)
      raise TransactionError.new("Invalid contract protocol: #{contract_protocol}")
    end
    
    contract_class = "Contracts::#{contract_protocol}".constantize
    new_contract = contract_class.create!(contract_id: ethscription.ethscription_id)
    
    self.contract_id = new_contract.contract_id
  end
  
  def initial_contract_proxy
    @initial_contract_proxy ||= create_execution_context_for_call(contract_id, tx.origin)
  end
  
  def execute_static_call
    begin
      initial_contract_proxy.send(function_name, function_args)
    rescue ContractError => e
      raise StaticCallError.new("Static Call error #{e.message}")
    end
  end
  
  def execute_transaction
    begin
      ActiveRecord::Base.transaction do
        ensure_valid_deploy!
        
        initial_contract_proxy.send(function_name, function_args).tap do
          call_receipt.status = :success
        end
      end
    rescue ContractError, TransactionError => e
      call_receipt.error_message = e.message
      call_receipt.status = is_deploy? ? :deploy_error : :call_error
    ensure
      ActiveRecord::Base.transaction do
        call_receipt.contract_id = contract_id

        call_receipt.save!
      end
    end
  end
  
  def is_deploy?
    operation == :deploy
  end
  
  def log_event(event)
    call_receipt.logs << event
  end
  
  def self.valid_contract_types
    Contracts.constants.map do |c|
      Contracts.const_get(c).to_s.demodulize
    end
  end
end