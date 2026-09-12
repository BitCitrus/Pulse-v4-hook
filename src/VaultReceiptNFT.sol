// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title VaultReceiptNFT
/// @notice Minimal ERC721 receipt for PulseV4Hook vault positions.
///         Each token represents an amount of vault shares. Only the HOOK can mint/burn.
contract VaultReceiptNFT {
    string public constant NAME = "PulseV4 Vault Position";
    string public constant SYMBOL = "PV4-VP";

    // --- ERC721 core storage ---
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // --- Hook-managed share accounting ---
    /// @notice Address of the HOOK contract that controls mint/burn
    address public immutable HOOK;

    /// @notice Vault share amount associated with each token ID
    mapping(uint256 => uint256) public shares;

    // --- Errors ---
    error NotHook();
    error NotAuthorized();
    error InvalidRecipient();
    error TokenDoesNotExist();

    // --- ERC721 Events ---
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(
        address indexed owner, address indexed approved, uint256 indexed tokenId
    );
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    constructor(address _hook) {
        HOOK = _hook;
    }

    modifier onlyHook() {
        _onlyHook();
        _;
    }

    function _onlyHook() internal {
        if (msg.sender != HOOK) revert NotHook();
    }

    // -----------------------------------------------------------------------
    // Hook-only functions
    // -----------------------------------------------------------------------

    function mint(address to, uint256 tokenId, uint256 shareAmount) external onlyHook {
        if (to == address(0)) revert InvalidRecipient();
        if (_owners[tokenId] != address(0)) revert("ERC721: token exists");
        _owners[tokenId] = to;
        unchecked {
            _balances[to]++;
        }
        shares[tokenId] = shareAmount;
        emit Transfer(address(0), to, tokenId);
    }

    function burn(uint256 tokenId) external onlyHook {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist();
        delete _owners[tokenId];
        delete shares[tokenId];
        delete _tokenApprovals[tokenId];
        unchecked {
            _balances[owner]--;
        }
        emit Transfer(owner, address(0), tokenId);
    }

    // -----------------------------------------------------------------------
    // ERC721 view
    // -----------------------------------------------------------------------

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist();
    }

    function balanceOf(address owner) public view returns (uint256) {
        return _balances[owner];
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x80ac58cd // ERC721
            || interfaceId == 0x5b5e139f // ERC721Metadata
            || interfaceId == 0x01ffc9a7; // ERC165
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return string(abi.encodePacked("pfnt://vault/", _uintToString(tokenId)));
    }

    // -----------------------------------------------------------------------
    // ERC721 transfers
    // -----------------------------------------------------------------------

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) {
            revert NotAuthorized();
        }
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (ownerOf(tokenId) != from) revert NotAuthorized();
        if (to == address(0)) revert InvalidRecipient();
        if (
            msg.sender != from && msg.sender != _tokenApprovals[tokenId]
                && !isApprovedForAll(from, msg.sender)
        ) {
            revert NotAuthorized();
        }
        delete _tokenApprovals[tokenId];
        unchecked {
            _balances[from]--;
            _balances[to]++;
        }
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata)
        external
    {
        transferFrom(from, to, tokenId);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _uintToString(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) digits++;
        tmp /= 10;
        bytes memory buf = new bytes(digits);
        while (v != 0) digits--;
        buf[digits] = bytes1(uint8(48 + v % 10));
        v /= 10;
        return string(buf);
    }
}
