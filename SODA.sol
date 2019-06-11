pragma solidity 0.5.9;
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/math/SafeMath.sol";
import "https://github.com/oraclize/ethereum-api/oraclizeAPI.sol";


contract EthPool is Ownable{
    function () external payable{}
    function send(address payable to, uint value) public onlyOwner  {
        to.transfer(value);
    }  
    function balance() public view returns(uint) {
        return address(this).balance;
    }
}

contract SODA is usingOraclize, Ownable {
    uint constant ORACLIZE_GASLIMIT = 250000;
    using SafeMath for uint;
    
    // Main
    // IERC20 WBTC = IERC20(0x002260fac5e5542a773aa44fbcfedf7c193bc2c599);
    // IERC20 USDC = IERC20(0x00a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48);
    // IERC20 TUSD = IERC20(0x000000000000085d4780B73119b644AE5ecd22b376);
    // IERC20 DAI  = IERC20(0x0089d24a6b4ccb1b6faa2625fe562bdd9a23260359); 
    
    // Ropsten
    IERC20 WBTC = IERC20(0x0065058d7081fcdc3cd8727dbb7f8f9d52cefdd291);
    IERC20 USDC = IERC20(0x00b8ccfdd060599d5cc9d16e8fdecc7da4492efce7);
    IERC20 TUSD = IERC20(0x0011ece4881ee4bb562e314ed9161f97072c7d89da);
    IERC20 DAI  = IERC20(0x000257d644608537ecd4bdcae094ba14da4d598a81); 
    
    EthPool public pool = new EthPool();
    event DepositAccepted(
        address user,
        uint WBTCamount,
        uint usdStartPrice,
        uint debt,
        uint timeStamp);
    mapping (address => Deposit) deposits;
    modifier oraclized() {
        uint price = oraclize_getPrice("URL", ORACLIZE_GASLIMIT);
        require(price <= msg.value, "need more eth");
        msg.sender.transfer( msg.value - price);
        _;
    }
    
    mapping (bytes32 => Transaction) queries;
    function deposit(uint256 value) public payable oraclized returns(bytes32 id) {
        require(WBTC.allowance(msg.sender, address(this)) >= value, "need approving");
        require(WBTC.balanceOf(msg.sender) >= value, "need more WBTC");
        require(deposits[msg.sender].state != DepositState.Active, "already Active");
        id = oraclize_query("URL", "json(https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT).price", ORACLIZE_GASLIMIT);
        queries[id] = Transaction(TransactionType.Deposit, msg.sender, value);
    }
    
    function getWbtcBalance() view public returns (uint256) {
        return WBTC.balanceOf(address(this));
    }
    function parseUsdPrice(string memory s) pure public returns (uint result) {
        bytes memory b = bytes(s);
        uint i;
        result = 0;
        uint dotted = 2;
        uint stop = b.length;
        for (i = 0; i < stop; i++) {
            if(b[i] == ".") {
                if(b.length - i > 3){
                    stop = i + 3;
                    dotted = 0;
                } else
                    dotted -= b.length - i-1;
            }
            else {
                uint c = uint(uint8(b[i]));
                if (c >= 48 && c <= 57) {
                    result = result * 10 + (c - 48);
                }
            }
        }
        result *= 10 **dotted;
    }
    
    
    
    function depositState(address user) view public returns (DepositState) {
        return deposits[user].state;
    }
    function depositWBTCamount(address user) view public returns (uint) {
        return deposits[user].WBTCamount;
    }
    function depositUsdStartPrice(address user) view public returns (uint) {
        return deposits[user].usdStartPrice;
    }
    function depositDebt(address user) view public returns (uint) {
        return deposits[user].debt;
    }
    function depositBalance(address user) view public returns (uint) {
        return deposits[user].balance;
    }
    function depositTimeStamp(address user) view public returns (uint) {
        return deposits[user].timeStamp;
    }
    
    function __callback(bytes32 myid, string memory result) public {
        if (msg.sender != oraclize_cbAddress()) revert();
        uint price = parseUsdPrice(result);
        Transaction storage txn = queries[myid];
       
        if(txn._type == TransactionType.Deposit){
            WBTC.transferFrom(txn.sender, address(this), txn.value);
            uint soda_dep = txn.value.mul(price).mul(10**10).mul(10).div(14);
            soda_dep = soda_dep.div(10**18).mul(10**18);
            
            // comission = 1%
            uint comission =txn.value.div(140);
            WBTC.transfer(owner(), comission);
            deposits[txn.sender] = Deposit(DepositState.Active, txn.value.sub(comission), price, soda_dep, soda_dep, now);
        
            emit DepositAccepted(txn.sender, txn.value.sub(comission),price,soda_dep, now);
        } else if(txn._type == TransactionType.SodaSpend){
            Deposit storage d = deposits[txn.sender];
            d.balance = d.balance.sub(txn.value);
            pool.send(txn.sender,txn.value.div(price));
        } else if(txn._type == TransactionType.SodaReparing){
            Deposit storage _deposit = deposits[txn.sender];
            uint valSoda = txn.value.mul(price);
            if(valSoda >= _deposit.debt){
                uint change = valSoda.sub(_deposit.debt).div(price);
                address(pool).transfer(txn.value.sub(change));
                pool.send(txn.sender,_deposit.balance.div(price));
                txn.sender.transfer(change);
                WBTC.transfer(txn.sender, _deposit.WBTCamount);
                delete deposits[txn.sender];
            } else {
                address(pool).transfer(txn.value);
                _deposit.debt = _deposit.debt.sub(valSoda);
            }
        } else if(txn._type == TransactionType.LiquidationRequest){
            if(deposits[txn.sender].usdStartPrice.mul(11) > price.mul(14))
                _liquidate(txn.sender);
        }
        delete queries[myid];
    }
    
    function balanceOf(address addr) view public returns(uint){
        return deposits[addr].balance;
    }
    function myBalance() view public returns(uint){
        return deposits[msg.sender].balance;
    }
    function myDebt() view public returns(uint){
        return deposits[msg.sender].debt;
    }
    
    function repayWithETH() public payable returns(bytes32 id){
        uint o_price = oraclize_getPrice("URL", ORACLIZE_GASLIMIT);
        require(o_price < msg.value);
        id = oraclize_query("URL", "json(https://api.binance.com/api/v3/ticker/price?symbol=ETHUSDT).price", ORACLIZE_GASLIMIT);
        queries[id] = Transaction(TransactionType.SodaReparing, msg.sender, msg.value.sub(o_price));
    }
    
    
    function repayWithUSDC(uint value) public {
        Deposit storage d = deposits[msg.sender];
        uint soda = value.add(1).mul(10**14);
        if(soda >= d.debt){
            if(d.balance != 0)
                TUSD.transfer(msg.sender, d.balance.div(10**14));
            uint change = (soda - d.debt).div(10**14);
            USDC.transferFrom(msg.sender, address(this), value.sub(change));
            WBTC.transfer(msg.sender, d.WBTCamount);
            delete deposits[msg.sender];
        } else {
            d.debt = d.debt.sub(soda);
            USDC.transferFrom(msg.sender, address(this), value);
        }
    }
    
    function repayWithTUSD(uint value) public {
        Deposit storage d = deposits[msg.sender];
        uint soda = value.add(1).mul(10**2);
        if(soda >= d.debt){
            if(d.balance != 0)
                TUSD.transfer(msg.sender, d.balance.div(10**2));
            uint change = (soda - d.debt).div(10**2);
            TUSD.transferFrom(msg.sender, address(this), value.sub(change));
            WBTC.transfer(msg.sender, d.WBTCamount);
            delete deposits[msg.sender];
        } else {
            d.debt = d.debt.sub(soda);
            TUSD.transferFrom(msg.sender, address(this), value);
        }
    }
    
    function repayWithDAI(uint value)  public {
        Deposit storage d = deposits[msg.sender];
        uint soda = value.add(1).mul(10**2);
        if(soda >= d.debt){
            if(d.balance != 0)
                DAI.transfer(msg.sender, d.balance.div(10**2));
            uint change = (soda - d.debt).div(10**2);
            DAI.transferFrom(msg.sender, address(this), value.sub(change));
            WBTC.transfer(msg.sender, d.WBTCamount);
            delete deposits[msg.sender];
        } else {
            d.debt = d.debt.sub(soda);
            DAI.transferFrom(msg.sender, address(this), value);
        }
    }
    
    
    
    
    function exchangeToUSDC(uint value) public {
        Deposit storage d = deposits[msg.sender];
        d.balance = d.balance.sub(value);
        USDC.transfer(msg.sender, value.div(10**14));
    }
    
    function exchangeToTUSD(uint value) public {
        Deposit storage d = deposits[msg.sender];
        d.balance = d.balance.sub(value);
        TUSD.transfer(msg.sender, value.div(10**2));
    }
    
    function exchangeToDAI(uint value)  public {
        Deposit storage d = deposits[msg.sender];
        d.balance = d.balance.sub(value);
        DAI.transfer(msg.sender, value.div(10**2));
    }
    
    function exchangeToETH(uint value) public payable oraclized returns(bytes32 id){
        require(deposits[msg.sender].balance >= value);
        id = oraclize_query("URL", "json(https://api.binance.com/api/v3/ticker/price?symbol=ETHUSDT).price", ORACLIZE_GASLIMIT);
        queries[id] = Transaction(TransactionType.SodaSpend, msg.sender, value);
    }
    
    enum TransactionType { Deposit, SodaSpend, SodaReparing, LiquidationRequest }
    struct Transaction {
        TransactionType _type;
        address payable sender;
        uint256 value;
    }
    
    enum DepositState {Closed, Active}
    struct Deposit {
        DepositState state;
        uint WBTCamount;
        uint usdStartPrice;
        uint debt;
        uint balance;
        uint timeStamp;
    }
    
    function drainAllPools() public onlyOwner {
        USDC.transfer(owner(), USDC.balanceOf(address(this)));
        TUSD.transfer(owner(), TUSD.balanceOf(address(this)));
        DAI .transfer(owner(), DAI .balanceOf(address(this)));
        pool.send(msg.sender, pool.balance());
    }
    
    function _liquidationRequest(address payable user) private oraclized returns(bytes32 id){
        id = oraclize_query("URL", "json(https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT).price", ORACLIZE_GASLIMIT);
        queries[id] = Transaction(TransactionType.LiquidationRequest, user, 0);
    }
    
    function _liquidate(address user) private {
        Deposit storage d = deposits[user];
        require(d.state == DepositState.Active);
        WBTC.transfer(owner(), d.WBTCamount);
        delete deposits[user];
    } 
    
    function liquidate(address payable user) public onlyOwner payable {
        Deposit storage _deposit = deposits[user];
        require(_deposit.state == DepositState.Active, "Deposit is Closed or doesn't exist");
        if(now > _deposit.timeStamp + 30 days)
            _liquidate(user);
        else
            _liquidationRequest(user);
    }
}
