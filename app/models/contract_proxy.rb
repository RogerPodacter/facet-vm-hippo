class ContractProxy
  include ContractErrors
  
  attr_accessor :contract, :operation

  def initialize(contract, operation:)
    @contract = contract
    @operation = operation
    define_contract_methods
  end
  
  def method_missing(name, *args, &block)
    raise ContractError.new("Call to unknown function #{name}", contract)
  end

  private
  
  def abi
    contract.abi
  end

  def define_contract_methods
    filtered_abi = contract.public_abi.select do |name, func|
      case operation
      when :static_call
        func.read_only?
      when :call
        !func.constructor?
      when :deploy
        true
      end
    end
    
    filtered_abi.each do |name, _|
      define_singleton_method(name) do |args|
        contract.execute_function(name, args)
      end
    end
  end
end
