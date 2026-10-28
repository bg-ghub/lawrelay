class MakeAssignmentLanguagesOptional < ActiveRecord::Migration[8.1]
  def change
    change_column_default :assignments, :languages, from: "NL", to: nil
    change_column_null :assignments, :languages, true
  end
end
