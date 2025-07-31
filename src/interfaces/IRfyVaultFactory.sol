// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IRfyVaultFactory
 * @dev Interface for the RfyVaultFactory contract
 * @author Shivansh
 * @notice Defines the interface for creating new RfyVault instances
 */
interface IRfyVaultFactory {
    /**
     * @dev Emitted when a new RfyVault is created
     * @param vaultAddress The address of the newly created RfyVault
     * @param asset The address of the asset token used by the RfyVault
     * @param externalVault The address of the external vault used by the RfyVault
     */
    event VaultCreated(
        address indexed vaultAddress,
        address asset,
        address externalVault
    );
    
    /**
     * @dev Emitted when a deployer is updated
     * @param _deployer The address of the deployer
     * @param _status The status of the deployer (true if added, false if removed)
     */
    event DeployerUpdated(address indexed _deployer, bool _status);

    /// @dev Error thrown when  address is invalid
    error SVF_InvalidAddress();

    /// @dev Error thrown when external vault address is invalid
    error SVF_InvalidExternalVaultAddress();

    /// @dev Error thrown when implementation address is invalid
    error SVF_InvalidImplementationAddress();
    
    /// @dev Error thrown when implementation address is invalid
    error SVF_NotDeployer();

    /**
     * @notice Creates a new RfyVault instance
     * @dev Only callable by the contract owner
     * @param _tokenName The name for the vault token
     * @param _tokenSymbol The symbol for the vault token
     * @param _asset The address of the asset token to be used in the vault
     * @param _owner The address that will receive admin role
     * @param _trader The address that will receive trader role
     * @param _externalVault The address of the external vault to be used
     * @param _epochDuration The duration of epochs in seconds
     * @return The address of the newly created RfyVault
     */
    function createVault(
        string calldata _tokenName,
        string calldata _tokenSymbol,
        string calldata _memeName,
        address _asset,
        address _owner,
        address _trader,
        address _externalVault,
        uint256 _epochDuration,
        uint256 _maxTotalDeposits
    ) external returns (address);

    /**
     * @notice Returns the address of the vault implementation used for cloning
     * @return The address of the vault implementation contract
     */
    function rfyVaultImplementation() external view returns (address);

    /**
     * @notice Update a address as deployer
     * @dev Only invokable by owner
     * @param _deployer address of the deployer
     * @param _status status of the deployer
     */
    function updateDeployer(address _deployer, bool _status) external;

    /**
     * @notice Returns whether the addres is a deployer or not
     * @param _deployer address of the deployer
     * @return status where address is a deployewr
     */
    function deployers(address _deployer) external view returns (bool); 
}