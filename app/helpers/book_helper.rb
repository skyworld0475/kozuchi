module BookHelper

class AccountGroup
  attr_reader :name, :accounts

  def self.groups(accounts, is_asc)
    groups = []
    for account in accounts do
      case account.account_type
        when 1
          assets = AccountGroup.new("口座") if !assets
          assets << account
        when 2
          expenses = AccountGroup.new("費目") if !expenses
          expenses << account
        when 3
          incomes = AccountGroup.new("収入内訳") if !incomes
          incomes << account
      end
    end
    if (is_asc)
      groups << assets if assets
      groups << expenses if expenses
      groups << incomes if incomes
    else
      groups << expenses if expenses
      groups << assets if assets
      groups << incomes if incomes
    end
    return groups
  end
  
  def initialize(name)
    @name = name
    @accounts = []
  end
  
  def <<(account)
    @accounts << account
  end
end

def format_deal(deal)
  return "記入 #{deal.date}-#{deal.daily_seq}"
end

class DateSpan
end

end
