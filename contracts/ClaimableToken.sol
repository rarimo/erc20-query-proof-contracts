// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {Groth16VerifierHelper} from "@solarity/solidity-lib/libs/zkp/Groth16VerifierHelper.sol";

import {IPoseidonSMT} from "@rarimo/passport-contracts/interfaces/state/IPoseidonSMT.sol";
import {AQueryProofExecutor} from "@rarimo/passport-contracts/sdk/AQueryProofExecutor.sol";
import {PublicSignalsBuilder} from "@rarimo/passport-contracts/sdk/lib/PublicSignalsBuilder.sol";

import {PoseidonUnit3L} from "./libraries/Poseidon.sol";

contract ClaimableToken is
    AQueryProofExecutor,
    ERC20Upgradeable,
    ERC165,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using PublicSignalsBuilder for uint256;

    using Groth16VerifierHelper for address;

    struct UserData {
        uint256 nullifier;
        uint256 identityCreationTimestamp;
    }

    uint256 public constant IDENTITY_LIMIT = type(uint32).max;

    uint256 public constant SELECTOR = 0x9A01; // 0b1101000000001

    uint256 public constant BIRTHDAY_UPPERBOUND = 0x303430333230; // 040320

    uint256 public rewardAmount;
    uint256 public claimingStartTimestamp;

    mapping(uint256 nullifier => bool) public isClaimed;
    mapping(address user => bool) public isClaimedByAddress;

    error AlreadyClaimed(uint256 nullifier);

    function __ClaimableToken_init(
        uint256 rewardAmount_,
        address registrationSMT_,
        address verifier_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(_msgSender());
        __AQueryProofExecutor_init(registrationSMT_, verifier_);

        rewardAmount = rewardAmount_;

        claimingStartTimestamp = block.timestamp;
    }

    function _beforeVerify(bytes32, uint256, bytes memory userPayload_) public override {
        (address receiver_, UserData memory userData_) = abi.decode(
            userPayload_,
            (address, UserData)
        );

        require(!isClaimed[userData_.nullifier], AlreadyClaimed(userData_.nullifier));
        isClaimed[userData_.nullifier] = true;
        isClaimedByAddress[receiver_] = true;
    }

    function _afterVerify(bytes32, uint256, bytes memory userPayload_) public override {
        (address receiver_, UserData memory userData_) = abi.decode(
            userPayload_,
            (address, UserData)
        );

        _mint(receiver_, rewardAmount);
    }

    function _buildPublicSignals(
        bytes32,
        uint256 currentDate_,
        bytes memory userPayload_
    ) public override returns (uint256 dataPointer_) {
        (address receiver_, UserData memory userData_) = abi.decode(
            userPayload_,
            (address, UserData)
        );

        /**
         * By default we check that the identity is created before the identityCreationTimestampUpperBound (proposal start)
         *
         * ROOT_VALIDITY is subtracted to address the issue with multi accounts if they are created right before the voting.
         * The registration root will still be valid and a user may bring 100 roots to vote 100 times.
         */
        uint256 identityCreationTimestampUpperBound = getIdentityCreationTimestampUpperBound();
        uint256 identityCounterUpperBound = IDENTITY_LIMIT;

        // If identity is issued after the proposal start, it should not be reissued more than identityCounterUpperBound
        if (userData_.identityCreationTimestamp > 0) {
            identityCreationTimestampUpperBound = userData_.identityCreationTimestamp;
            identityCounterUpperBound = 1;
        }

        dataPointer_ = PublicSignalsBuilder.newPublicSignalsBuilder(SELECTOR, userData_.nullifier);
        dataPointer_.withEventIdAndData(getEventId(receiver_), getEventData());
        dataPointer_.withCurrentDate(currentDate_, 1 days);
        dataPointer_.withTimestampLowerboundAndUpperbound(0, identityCreationTimestampUpperBound);
        dataPointer_.withBirthDateLowerboundAndUpperbound(
            PublicSignalsBuilder.ZERO_DATE,
            BIRTHDAY_UPPERBOUND
        );
        dataPointer_.withIdentityCounterLowerbound(0, identityCounterUpperBound);
        dataPointer_.withExpirationDateLowerboundAndUpperbound(
            currentDate_,
            PublicSignalsBuilder.ZERO_DATE
        );

        return dataPointer_;
    }

    function getIdentityCreationTimestampUpperBound() public view returns (uint256) {
        return claimingStartTimestamp - IPoseidonSMT(getRegistrationSMT()).ROOT_VALIDITY();
    }

    function getEventId(address receiver_) public view returns (uint256) {
        return
            PoseidonUnit3L.poseidon(
                [block.chainid, uint256(uint160(address(this))), uint256(uint160(receiver_))]
            );
    }

    function getEventData() public view returns (uint256) {
        return uint256(uint248(uint256(keccak256(abi.encodePacked(rewardAmount)))));
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function isUserClaimed(uint256 nullifier) public view returns (bool) {
        return isClaimed[nullifier];
    }

    function isUserClaimedByAddress(address user) public view returns (bool) {
        return isClaimedByAddress[user];
    }

    /**
     * @inheritdoc ERC165
     */
    function supportsInterface(bytes4 interfaceId_) public view override returns (bool) {
        return super.supportsInterface(interfaceId_);
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
