class AllowRemoteLegalTasks < ActiveRecord::Migration[8.1]
  def up
    change_column_null :assignments, :city, true
  end

  def down
    execute "UPDATE assignments SET city = '' WHERE city IS NULL"
    change_column_null :assignments, :city, false
  end
end
