class Contract < ApplicationRecord
  self.inheritance_column = :_type_disabled
  
  include ContractErrors
    
  has_many :states, primary_key: 'address', foreign_key: 'contract_address', class_name: "ContractState"
  has_one :newest_state, -> { newest_first }, class_name: 'ContractState', primary_key: 'address',
    foreign_key: 'contract_address'
  belongs_to :contract_transaction, foreign_key: :transaction_hash, primary_key: :transaction_hash, optional: true

  belongs_to :ethscription, primary_key: 'ethscription_id', foreign_key: 'transaction_hash'
  
  has_many :contract_calls, foreign_key: :effective_contract_address, primary_key: :address
  has_many :contract_transactions, through: :contract_calls
  has_many :contract_transaction_receipts, through: :contract_transactions
  
  has_one :creating_contract_call, class_name: 'ContractCall', foreign_key: 'created_contract_address', primary_key: 'address'

  attr_reader :implementation
  
  delegate :implements?, to: :implementation
  
  def get_implementation_from_code_string(code_string)
    RubidityInterpreter.build_implementation_class_from_code_string(type, code_string)
  end
  
  class << self
    delegate :valid_contract_types, to: ContractImplementation
  end
  
  def implementation
    @implementation ||= implementation_class.new
  end
  
  def implementation_class
    # binding.pry

    "Contracts::#{type}".safe_constantize ||
      get_implementation_from_code_string(TransactionContext.valid_contracts.send(type))
  end
  
  def self.type_abstract?(type)
    # TODO
    "Contracts::#{type}".safe_constantize&.is_abstract_contract || false
  end
  
  def self.type_valid?(type)
    # binding.pry
    Contract.valid_contract_types.include?(type.to_sym) ||
    TransactionContext.valid_contracts.send(type).present?
  end
  
  def execute_function(function_name, args)
    with_state_management do
      if args.is_a?(Hash)
        implementation.public_send(function_name, **args)
      else
        implementation.public_send(function_name, *Array.wrap(args))
      end
    end
  end
  
  def with_state_management
    state_changed = false
    
    implementation.state_proxy.load(latest_state.deep_dup)
    initial_state = implementation.state_proxy.serialize
    
    result = yield.tap do
      final_state = implementation.state_proxy.serialize
      
      if final_state != initial_state
        states.create!(
          transaction_hash: TransactionContext.transaction_hash,
          block_number: TransactionContext.block_number,
          transaction_index: TransactionContext.transaction_index,
          internal_transaction_index: TransactionContext.current_call.internal_transaction_index,
          state: final_state
        )
        
        state_changed = true
      end
    end
    
    { result: result, state_changed: state_changed }
  end
  
  def fresh_implementation_with_latest_state
    implementation_class.new(self).tap do |implementation|
      implementation.state_proxy.load(latest_state.deep_dup)
    end
  end
  
  def self.all_abis(deployable_only: false)
    contract_classes = valid_contract_types

    contract_classes.each_with_object({}) do |name, hash|
      contract_class = "Contracts::#{name}".constantize

      next if deployable_only && contract_class.is_abstract_contract

      hash[contract_class.name] = contract_class.public_abi
    end.transform_keys(&:demodulize)
  end
  
  def as_json(options = {})
    super(
      options.merge(
        only: [
          :address,
          :transaction_hash,
        ]
      )
    ).tap do |json|
      json['abi'] = implementation.public_abi.map do |name, func|
        [name, func.as_json.except('implementation')]
      end.to_h
      
      json['current_state'] = latest_state
      json['current_state']['contract_type'] = type.demodulize
      
      klass = implementation.class
      tree = [klass, klass.linearized_parents].flatten
      
      json['source_code'] = tree.map do |k|
        {
          language: 'ruby',
          code: source_code(k)
        }
      end
    end
  end
  
  def static_call(name, args = {})
    ContractTransaction.make_static_call(
      contract: address, 
      function_name: name, 
      function_args: args
    )
  end

  def source_file(type)
    ActiveSupport::Dependencies.autoload_paths.each do |base_folder|
      relative_path = "#{type.to_s.underscore}.rb"
      absolute_path = File.join(base_folder, relative_path)

      return absolute_path if File.file?(absolute_path)
    end
    nil
  end

  def source_code(type)
    File.read(source_file(type)) if source_file(type)
  end
end
