// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Clones } from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import { RfyVault } from "./RfyVault.sol";
import { IRfyVaultFactory } from "./interfaces/IRfyVaultFactory.sol";

/**
 * @title RfyVaultFactory
 * @dev Factory contract for deploying new RfyVault instances
 * @author Shivansh
 * @notice This contract allows the owner to deploy new RfyVault contracts with specified parameters
 */
contract RfyVaultFactory is Ownable, IRfyVaultFactory {
	address public immutable override rfyVaultImplementation;
	
	/// @dev deployers mapping to track addresses allowed to create vaults
	mapping(address => bool) public override deployers;

	/**
	 * @dev Constructor that initializes the Ownable parent contract and sets the implementation address
	 * @param _rfyVaultImplementation The address of the RfyVault implementation to be cloned
	 */
	constructor(address _rfyVaultImplementation) Ownable(msg.sender) {
		if (_rfyVaultImplementation == address(0)) revert SVF_InvalidImplementationAddress();
		rfyVaultImplementation = _rfyVaultImplementation;
		deployers[msg.sender] = true;
	}

	function updateDeployer(address _deployer, bool _status) external onlyOwner {
		if (_deployer == address(0)) revert SVF_InvalidAddress();
		deployers[_deployer] = _status;
		emit DeployerUpdated(_deployer, _status);
	}	

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
	) external override returns (address) {

		if(!deployers[msg.sender]) revert SVF_NotDeployer();

		if (_asset == address(0) || _owner == address(0) || _trader == address(0)) {
			revert SVF_InvalidAddress();
		}

		address newVault = Clones.clone(rfyVaultImplementation);

		RfyVault(newVault).initialize(
			_tokenName,
			_tokenSymbol,
			_memeName,
			_asset,
			_owner,
			_trader,
			_externalVault,
			_epochDuration,
			_maxTotalDeposits
		);

		emit VaultCreated(address(newVault), _asset, _externalVault);

		return address(newVault);
	}
}
