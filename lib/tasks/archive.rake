namespace :archive do
    desc 'Move data from main database to archive database task'
    task :archive do
        main = Mysql2::Client.new(:host => "localhost", :username => "root", :password => 'changeme')
        archive = Mysql2::Client.new(:host => "localhost", :username => "root", :password => 'changeme')

        id_list = Member.all.map(&:id)

        orders = main.query("SELECT `orders`.* FROM `orders` WHERE (datetime <= Archivedate)")
        archive.query("INSERT INTO `orders` (?)", orders)
        id_list.for_each do |id|
            main.query("DELETE FROM `orders` WHERE (member_id === (?) AND trades === (?))", id, [])
        end

        trades = main.query("SELECT `trades`.* FROM `trades` WHERE (datetime <= Archivedate)")
        archive.query("INSERT INTO `trades` (?)", trades)

        revenues = main.query("SELECT `revenues`.* FROM `revenues` WHERE (datetime <= Archivedate)")
        archive.query("INSERT INTO `revenues` (?)", revenues.compact!)

        liabilities = main.query("SELECT `liabilities`.* FROM `liabilities` WHERE (datetime <= Archivedate)")
        archive.query("INSERT INTO `liabilities` (?)", liabilities.compact!)
    end
end
