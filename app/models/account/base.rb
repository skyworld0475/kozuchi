class Account::Base < ActiveRecord::Base
  set_table_name "accounts"

  # ---------- 口座種別の静的属性を設定するためのメソッド群

  # クラス名に対応する Symbol　を返す。  
  def self.to_sym
    self.name.demodulize.underscore.to_sym
  end
  
  # Symbolに対応するクラスを返す。Accountモジュール下にないクラスの場合は例外を発生する。
  # sym:: Symbol
  def self.sym_to_class(sym)
    eval "Account::#{sym.to_s.camelize}" # ネストしたクラスなので eval で
  end
  
  def type_in?(type)
    t = self.class.sym_to_class(type) unless type.kind_of?(Class) # TODO: Classのとき動かなそうだな
    self.kind_of? t
  end

  # すぐ下の派生クラスの配列を返す。Base は口座種別、Assetは資産種別となる
  def self.types
    @types ||= []
    return @types.clone
  end

  # 継承されたときは口座種類配列を更新する
  def self.inherited(subclass)
    @types ||= []
    @types << subclass unless @types.include?(subclass)
    super
  end
  
  def self.type_order(order = nil)
    @type_order ||= 0
    return @type_order unless order
    @type_order = order
  end
  
  # 口座種類配列をソートする
  def self.sort_types
    @types ||= []
    @types.sort!{|a, b| a.type_order <=> b.type_order}
  end
  
  def self.type_name(name = nil)
    return @type_name unless name
    @type_name = name
  end
  
  def self.short_name(short_name = nil)
    return @short_name unless short_name
    @short_name = short_name
  end
  
  def self.connectable_type(clazz = nil)
    return @connectable_type unless clazz
    @connectable_type = clazz
  end

  # 勘定名（勘定種類 or 資産種類)
  # TODO: リファクタリングしたい
  def name_with_asset_type
    "#{self.name}(#{self.kind_of?(Asset) ? self.class.asset_name : self.class.short_name})"
  end

  # TODO: 呼び出し側のリファクタリング確認
  # 資産口座種類名を返す。資産口座でなければnilを返す。
  def asset_type_name
    self.class.kind_of?(Asset) ? self.class.asset_name : nil
  end

  # TODO: 呼び出し側のリファクタリング確認
  # with_asset_type の前にユーザー名をつけたもの
  def name_with_user
    return "#{user.login_id} さんの #{name_with_asset_type}"
  end
  
  # ---------- 機能

  include TermHelper
  belongs_to :user

  has_and_belongs_to_many :connected_accounts,
                          :class_name => 'Account::Base',
                          :join_table => 'account_links',
                          :foreign_key => 'connected_account_id',
                          :association_foreign_key => 'account_id'

  has_and_belongs_to_many :associated_accounts,
                          :class_name => 'Account::Base',
                          :join_table => 'account_links',
                          :foreign_key => 'account_id',
                          :association_foreign_key => 'connected_account_id'

  belongs_to              :partner_account,
                          :class_name => 'Account::Base',
                          :foreign_key => 'partner_account_id'

  # any_entry:: 削除可能性チェックのために用意。削除可能性チェック結果表示のための一覧では include すること。
  has_one                 :any_entry,
                          :class_name => 'AccountEntry',
                          :foreign_key => 'account_id'
  
  attr_accessor :balance, :percentage
  validates_presence_of :name,
                        :message => "名前を定義してください。"
  #TODO: 口座・費目・収入内訳を動的に作りたいが、現状の方針だとできない 
  validates_uniqueness_of :name, :scope => 'user_id', :message => "口座・費目・収入内訳で名前が重複しています。"
  validate :validates_partner_account
  before_destroy :assert_not_used

  # 削除可能性を調べる
  def deletable?
    @delete_errors = []
    begin
      assert_not_used(false) # キャッシュを使う
      return true
    rescue Account::UsedAccountException => err
      delete_errors << err.message
      return false
    end
  end
  
  # deletable? を実行したときに更新される削除エラーメッセージの配列を返す。
  def delete_errors
    @delete_errors ||= []
    @delete_errors
  end

  # 連携設定 ------------------

  def connect(target_user_login_id, target_account_name, interactive = true)
    friend_user = User.find_friend_of(self.user_id, target_user_login_id)
    raise "no friend user" unless friend_user

    connected_account = Account::Base.get_by_name(friend_user.id, target_account_name)
    raise "フレンド #{partner_user.login_id} さんには #{target_account_name} がありません。" unless connected_account

    raise "すでに連動設定されています。" if connected_accounts.detect {|e| e.id == connected_account.id} 
    
    raise "#{account_type_name} には #{connected_account.account_type_name} を連動できません。" unless self.kind_of?(connected_account.class.connectable_type)
    connected_accounts << connected_account
    # interactive なら逆リンクもはる。すでにあったら黙ってパスする
    associated_accounts << connected_account if interactive && !associated_accounts.detect {|e| e.id == connected_account.id}
    save!
  end

  def clear_connection(connected_account)
    connected_accounts.delete(connected_account)
  end

  def connected_or_associated_accounts_size
    size = connected_accounts.size
    for account in associated_accounts
      size += 1 unless connected_accounts.detect{|e| e.id == account.id}
    end
    return size
  end

  def self.get(user_id, account_id)
    return Account::Base.find(:first, :conditions => ["user_id = ? and id = ?", user_id, account_id])
  end
  
  def self.get_by_name(user_id, name)
    return Account::Base.find(:first, :conditions => ["user_id = ? and name = ?", user_id, name])
  end

  # 口座別計算メソッド
  
  # 指定された日付より前の時点での残高を計算して balance に格納する
  # TODO: 格納したくない。返り値の利用でいい人はそうして。
  def balance_before(date)
    @balance = AccountEntry.balance_at_the_start_of(self.user_id, self.id, date)
  end

  # 口座の初期設定を行う
  def self.create_default_accounts(user_id)
    # 口座
    Cache.create_accounts(user_id, ['現金'])
    # 支出
    Expense.create_accounts(user_id, ['食費','住居・備品','水・光熱費','被服・美容費','医療費','理容衛生費','交際費','交通費','通信費','教養費','娯楽費','税金','保険料','雑費','予備費','教育費','自動車関連費'])
    # 収入
    Income.create_accounts(user_id, ['給料', '賞与', '利子・配当', '贈与'] )
  end
  
  protected
  def self.create_accounts(user_id, names, sort_key_start = 1)
    sort_key = sort_key_start
    for name in names
      self.create(:user_id => user_id, :name => name, :sort_key => sort_key)
      sort_key += 1
    end
  end

  def validates_partner_account
    # 連動設定のチェックは有効だがバリデーションエラーでもなぜかリンクは張られてしまうため連動追加メソッド側でチェック
    # 受け皿口座が同じユーザーであることをチェック  TODO: ＵＩで制限しているため、単体テストにて確認したい
    if partner_account
      errors.add(:partner_account_id, "同じユーザーの口座しか受け皿口座に設定できません。") unless partner_account.user_id == self.user_id
    end
  end
  
  # 使われていないことを確認する。
  # force:: true ならその時点でデータベースを新しく調べる。 false ならキャッシュを利用する。
  def assert_not_used(force = true)
    # 使われていたら消せない
    raise Account::UsedAccountException.new(self.class.type_name, name) if self.any_entry(force)
  end

end

# require ではrails的に必要な文脈で確実にリロードされないので参照する
for d in Dir.glob(File.expand_path(File.dirname(__FILE__)) + '/*')
  clazz = d.scan(/.*\/(account\/.*).rb$/).to_s.camelize
  eval clazz
end
#ObjectSpace.each_object(Class){|o| o}

Account::Base.sort_types
Account::Asset.sort_types

# データがある勘定を削除したときに発生する例外
class Account::UsedAccountException < Exception
  def initialize(account_type_name, account_name)
    super(self.class.new_message(account_type_name, account_name))
  end
  def self.new_message(account_type_name, account_name)
    "#{account_type_name}「#{account_name}」はすでに使われているため削除できません。"
  end
end