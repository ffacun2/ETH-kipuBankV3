// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
// Control de acceso de V2
import "@openzeppelin/contracts/access/Ownable.sol";
// Helpers y estándar ERC20 de V2
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// NUEVAS Interfaces para Uniswap y WETH
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";

/**
 * @title KipuBank V3
 * @author Facundo Criado
 */
contract KipuBank is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    /*//////////////////////////////////////////////////////////////
                            VARIABLES DE ESTADO
    //////////////////////////////////////////////////////////////*/

    /// @notice Limite de capitalizacion del banco, en la menor unidad de USDC (6 decimales).
    uint256 public immutable i_bankCapUSDC;

    /// @notice Limite de retiro por transaccion, en la menor unidad de USDC.
    uint256 public immutable i_withdrawalLimitUSDC;

    /// @notice Instancia del Router de Uniswap V2.
    IUniswapV2Router02 public immutable i_uniswapRouter;

    /// @notice Instancia del token USDC.
    IERC20 public immutable i_usdcToken;

    /// @notice Instancia del token WETH.
    IWETH public immutable i_weth;

    /// @notice Contabilidad de los saldos de usuarios (solo en USDC).
    mapping(address => uint256) public s_balancesUSDC;

    /// @notice Cantidad de depositos que se realizaron en el contrato.
    uint256 public s_depositCount;

    /// @notice Cantidad de retiros que se realizaron en el contrato.
    uint256 public s_withdrawalCount;

    /*//////////////////////////////////////////////////////////////
                                EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Evento emitido cuando un deposito se convierte y acredita en USDC.
    event Deposited(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcReceived
    );

    /// @notice Evento emitido cuando se retiran USDC.
    event Withdrawn(address indexed user, uint256 usdcAmount);

    /*//////////////////////////////////////////////////////////////
                                ERRORES
    //////////////////////////////////////////////////////////////*/

    error KipuBank__ZeroAmount();
    error KipuBank__InsufficientBalance(
        uint256 required,
        uint256 available
    );
    error KipuBank__WithdrawLimitExceeded(uint256 amount, uint256 limit);
    error KipuBank__BankCapExceeded(
        uint256 usdcToAdd,
        uint256 currentBalance,
        uint256 cap
    );
    error KipuBank__TransferFailed();
    error KipuBank__DeadlineExpired();
    error KipuBank__InvalidPath();
    error KipuBank__FallbackNotAllowed();

    /*//////////////////////////////////////////////////////////////
                                MODIFICADORES
    //////////////////////////////////////////////////////////////*/

    modifier nonZeroAmount(uint256 _amount) {
        if (_amount == 0) revert KipuBank__ZeroAmount();
        _;
    }

    modifier nonZeroValue() {
        if (msg.value == 0) revert KipuBank__ZeroAmount();
        _;
    }

    modifier checkDeadline(uint256 _deadline) {
        if (_deadline < block.timestamp) revert KipuBank__DeadlineExpired();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _bankCapUSDC Limite de capitalizacion en la menor unidad de USDC.
     * @param _withdrawalLimitUSDC Límite de retiro en la menor unidad de USDC.
     * @param _router Direccion del Router Uniswap V2.
     * @param _usdc Direccion del token USDC.
     * @param _weth Direccion del token WETH.
     */
    constructor(
        uint256 _bankCapUSDC,
        uint256 _withdrawalLimitUSDC,
        address _router,
        address _usdc,
        address _weth
    ) Ownable(msg.sender) {
        i_bankCapUSDC = _bankCapUSDC;
        i_withdrawalLimitUSDC = _withdrawalLimitUSDC;
        i_uniswapRouter = IUniswapV2Router02(_router);
        i_usdcToken = IERC20(_usdc);
        i_weth = IWETH(_weth);
    }

    /*//////////////////////////////////////////////////////////////
                    FUNCIONES CORE - DEPÓSITO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Permite depositar ETH, que se intercambiará por USDC.
     * @param _amountOutMin La cantidad mínima de USDC que se acepta recibir.
     * @param _deadline Límite de tiempo para la transacción de swap.
     */
    function depositEth(
        uint256 _amountOutMin,
        uint256 _deadline
    ) external payable nonZeroValue checkDeadline(_deadline) nonReentrant {
        // Valido Capacidad del Banco
        // Consulto cuanto USDC recibo ANTES de hacer el swap.
        address[] memory path = new address[](2);
        path[0] = address(i_weth);
        path[1] = address(i_usdcToken);


        // Ejecuto Swap (ETH -> USDC)
        uint256[] memory actualAmounts = i_uniswapRouter
            .swapExactETHForTokens{value: msg.value}(
            _amountOutMin,
            path,
            address(this), // El USDC se envia a este contrato
            _deadline
        );
        
        uint256 actualUsdcReceived = actualAmounts[1];

        // Valido contra el limite del banco
        _checkBankCap(actualUsdcReceived);

        //Acredito Saldo (Efecto)
        _creditUserUSDC(msg.sender, actualUsdcReceived);

        emit Deposited(
            msg.sender,
            address(0), // ETH
            msg.value,
            actualUsdcReceived
        );
    }

    /**
     * @notice Permite depositar USDC (directo) o cualquier otro ERC20 (con swap).
     * @param _token La dirección del token a depositar.
     * @param _amount La cantidad del token a depositar.
     * @param _amountOutMin La cantidad minima de USDC que se acepta recibir.
     * @param _deadline Limite de tiempo para la transaccion de swap.
     */
    function deposit(
        address _token,
        uint256 _amount,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external nonZeroAmount(_amount) checkDeadline(_deadline) nonReentrant {
        // Transfiero tokens al contrato
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 usdcReceived;

        if (_token == address(i_usdcToken)) {
            // Deposito directo de USDC
            
            usdcReceived = _amount;
            _checkBankCap(usdcReceived);
        } else {
            // Swap de Token -> USDC

            //Swap para obtener el valor real
            usdcReceived = _swapToUSDC(
                _token,
                _amount,
                _amountOutMin, 
                _deadline
            );

            //Valido Capacidad del Banco
            _checkBankCap(usdcReceived);
        }

        // Acredito el Saldo (Efecto)
        _creditUserUSDC(msg.sender, usdcReceived);

        emit Deposited(msg.sender, _token, _amount, usdcReceived);
    }

    /*//////////////////////////////////////////////////////////////
                    FUNCIONES CORE - RETIRO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Permite a un usuario retirar su saldo en USDC.
     * @param _amountUSDC La cantidad de USDC a retirar.
     */
    function withdraw(uint256 _amountUSDC) external nonZeroAmount(_amountUSDC) nonReentrant {
        // --- Checks ---
        if (_amountUSDC > i_withdrawalLimitUSDC) {
            revert KipuBank__WithdrawLimitExceeded(
                _amountUSDC,
                i_withdrawalLimitUSDC
            );
        }

        uint256 userBalance = s_balancesUSDC[msg.sender];
        if (_amountUSDC > userBalance) {
            revert KipuBank__InsufficientBalance(_amountUSDC, userBalance);
        }

        // --- Effects ---
        s_balancesUSDC[msg.sender] = userBalance - _amountUSDC;
        s_withdrawalCount++;

        // --- Interactions ---
        i_usdcToken.safeTransfer(msg.sender, _amountUSDC);

        emit Withdrawn(msg.sender, _amountUSDC);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS INTERNOS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Intercambia un token a USDC.
     * @return usdcReceived La cantidad de USDC recibida del swap.
     */
    function _swapToUSDC(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) private returns (uint256) {
        // Apruebo al router para que gaste el token
        IERC20(_tokenIn).forceApprove(address(i_uniswapRouter), _amountIn);

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = address(i_usdcToken);

        // Ejecuto el swap
        uint256[] memory actualAmounts = i_uniswapRouter.swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            path,
            address(this), // El USDC se recibe aca
            _deadline
        );

        return actualAmounts[1]; // Retorna la cantidad de USDC recibida
    }

    /**
     * @dev Verifica si añadir una cantidad de USDC excede el limite del banco.
     */
    function _checkBankCap(uint256 _usdcToAdd) private view {
        //El currentBalance ya incluye el _usdcToAdd porque el swap ya se hizo
        uint256 currentBalance = i_usdcToken.balanceOf(address(this));
        if (currentBalance > i_bankCapUSDC) {
            revert KipuBank__BankCapExceeded(
                _usdcToAdd,
                currentBalance - _usdcToAdd,
                i_bankCapUSDC
            );
        }
    }

    /**
     * @dev Acredita el saldo de USDC al usuario y aumenta el contador.
     */
    function _creditUserUSDC(address _user, uint256 _usdcAmount) private {
        s_balancesUSDC[_user] += _usdcAmount;
        s_depositCount++;
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES DE VISTA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Obtiene el saldo interno de USDC de un usuario.
     */
    function getUSDCBalance(address _user) external view returns (uint256) {
        return s_balancesUSDC[_user];
    }

    /**
     * @notice Obtiene el balance total de USDC que tiene el contrato.
     */
    function getTotalUSDCInBank() external view returns (uint256) {
        return i_usdcToken.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                    FUNCIONES DE CONTROL DE ACCESO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice (Owner) Permite retirar fondos de emergencia.
     * @dev No actualiza la contabilidad interna.
     */
    function emergencyWithdraw(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(0)) {
            (bool success, ) = owner().call{value: _amount}("");
            if (!success) revert KipuBank__TransferFailed();
        } else {
            IERC20(_token).safeTransfer(owner(), _amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        revert KipuBank__FallbackNotAllowed();
    }
    
    /**
     * @notice Rechaza cualquier llamada a funcion desconocida.
     */
    fallback() external payable {
        revert KipuBank__FallbackNotAllowed();
    }
}