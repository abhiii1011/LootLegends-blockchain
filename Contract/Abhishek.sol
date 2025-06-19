// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title LootLegends
 * @dev NFT-driven dungeon crawler where loot drops are minted as tradable NFTs
 */
contract LootLegends is ERC721, Ownable, ReentrancyGuard, Pausable {
    // Constants
    uint256 public constant MAX_SUPPLY = 10000;
    uint256 public constant COOLDOWN_PERIOD = 1 hours;
    uint256 public constant PLATFORM_FEE_PERCENT = 10;
   
    // State variables
    uint256 private _tokenIdCounter;
    string private _baseTokenURI;
    uint256 public dungeonBaseFee = 0.001 ether;
   
    // Structs
    struct LootItem {
        string name;
        uint8 rarity; // 1=Common, 2=Uncommon, 3=Rare, 4=Epic, 5=Legendary
        uint8 itemType; // 1=Weapon, 2=Armor, 3=Accessory, 4=Consumable
        uint16 power;
        uint16 defense;
        uint16 magic;
        uint32 timestamp;
    }
   
    struct Player {
        uint256 totalCrawls;
        uint256 totalLootFound;
        uint256 lastCrawlTime;
    }
   
    // Mappings
    mapping(uint256 => LootItem) public lootItems;
    mapping(address => Player) public players;
    mapping(address => mapping(uint8 => uint256)) public playerRarityCount;
   
    // Events
    event DungeonCompleted(
        address indexed player,
        uint256 dungeonLevel,
        uint256 tokenId,
        uint8 rarity
    );
   
    event LootTraded(
        uint256 indexed tokenId,
        address indexed from,
        address indexed to,
        uint256 price
    );
   
    event LootUpgraded(
        address indexed player,
        uint256[] burnedTokens,
        uint256 newTokenId
    );
   
    constructor(
        string memory baseTokenURI,
        address initialOwner
    ) ERC721("LootLegends", "LOOT") Ownable(initialOwner) {
        _baseTokenURI = baseTokenURI;
    }
   
    /**
     * @dev Core Function 1: Main gameplay function for dungeon exploration
     * @param dungeonLevel Difficulty level (1-10)
     */
    function dungeonCrawl(uint256 dungeonLevel)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(dungeonLevel >= 1 && dungeonLevel <= 10, "Invalid dungeon level");
        require(_tokenIdCounter < MAX_SUPPLY, "Max supply reached");
       
        Player storage player = players[msg.sender];
        require(
            block.timestamp >= player.lastCrawlTime + COOLDOWN_PERIOD,
            "Cooldown period active"
        );
       
        uint256 requiredFee = dungeonBaseFee * dungeonLevel;
        require(msg.value >= requiredFee, "Insufficient dungeon fee");
       
        // Generate pseudo-random loot
        uint256 randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    msg.sender,
                    _tokenIdCounter,
                    dungeonLevel
                )
            )
        );
       
        // Calculate rarity based on dungeon level
        uint8 rarity = _calculateRarity(randomSeed, dungeonLevel);
        uint8 itemType = uint8((randomSeed >> 8) % 4) + 1;
       
        // Create loot item
        uint256 tokenId = _tokenIdCounter;
        lootItems[tokenId] = LootItem({
            name: _generateLootName(rarity, itemType, randomSeed),
            rarity: rarity,
            itemType: itemType,
            power: uint16((randomSeed >> 16) % (rarity * 20) + rarity * 10),
            defense: uint16((randomSeed >> 32) % (rarity * 15) + rarity * 5),
            magic: uint16((randomSeed >> 48) % (rarity * 25) + rarity * 8),
            timestamp: uint32(block.timestamp)
        });
       
        // Update player stats
        player.totalCrawls++;
        player.totalLootFound++;
        player.lastCrawlTime = block.timestamp;
        playerRarityCount[msg.sender][rarity]++;
       
        // Mint NFT
        _mint(msg.sender, tokenId);
        _tokenIdCounter++;
       
        emit DungeonCompleted(msg.sender, dungeonLevel, tokenId, rarity);
       
        // Refund excess payment
        if (msg.value > requiredFee) {
            payable(msg.sender).transfer(msg.value - requiredFee);
        }
    }
   
    /**
     * @dev Core Function 2: Facilitates peer-to-peer loot trading
     * @param tokenId NFT token ID to trade
     * @param to Recipient address
     * @param price Trade price in wei
     */
    function tradeLoot(
        uint256 tokenId,
        address to,
        uint256 price
    ) external payable nonReentrant whenNotPaused {
        require(ownerOf(tokenId) == msg.sender, "Not token owner");
        require(to != address(0), "Invalid recipient");
        require(to != msg.sender, "Cannot trade to yourself");
        require(msg.value >= price, "Insufficient payment");
       
        address seller = msg.sender;
       
        // Calculate platform fee
        uint256 platformFee = (price * PLATFORM_FEE_PERCENT) / 100;
        uint256 sellerAmount = price - platformFee;
       
        // Transfer NFT
        _transfer(seller, to, tokenId);
       
        // Handle payments
        if (sellerAmount > 0) {
            payable(seller).transfer(sellerAmount);
        }
        // Platform fee stays in contract
       
        emit LootTraded(tokenId, seller, to, price);
       
        // Refund excess payment
        if (msg.value > price) {
            payable(msg.sender).transfer(msg.value - price);
        }
    }
   
    /**
     * @dev Core Function 3: Combines multiple loot items to create upgraded versions
     * @param tokenIds Array of token IDs to combine (2-5 items)
     */
    function upgradeLoot(uint256[] memory tokenIds)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(tokenIds.length >= 2 && tokenIds.length <= 5, "Invalid token count");
        require(_tokenIdCounter < MAX_SUPPLY, "Max supply reached");
       
        uint256 upgradeFee = 0.005 ether * tokenIds.length;
        require(msg.value >= upgradeFee, "Insufficient upgrade fee");
       
        // Validate ownership and calculate upgrade stats
        uint256 totalPower = 0;
        uint256 totalDefense = 0;
        uint256 totalMagic = 0;
        uint8 maxRarity = 0;
        uint8 dominantType = 0;
        uint256 typeCount = 0;
       
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(ownerOf(tokenIds[i]) == msg.sender, "Not owner of all tokens");
           
            LootItem memory item = lootItems[tokenIds[i]];
            totalPower += item.power;
            totalDefense += item.defense;
            totalMagic += item.magic;
           
            if (item.rarity > maxRarity) {
                maxRarity = item.rarity;
            }
           
            if (item.itemType == dominantType) {
                typeCount++;
            } else if (typeCount == 0) {
                dominantType = item.itemType;
                typeCount = 1;
            }
        }
       
        // Burn input tokens
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _burn(tokenIds[i]);
            delete lootItems[tokenIds[i]];
        }
       
        // Calculate new rarity (chance to upgrade)
        uint256 upgradeRandom = uint256(
            keccak256(abi.encodePacked(block.timestamp, msg.sender, tokenIds))
        );
        uint8 newRarity = maxRarity;
        if (upgradeRandom % 100 < 25 && maxRarity < 5) { // 25% chance to upgrade rarity
            newRarity = maxRarity + 1;
        }
       
        // Create upgraded loot
        uint256 newTokenId = _tokenIdCounter;
        lootItems[newTokenId] = LootItem({
            name: _generateLootName(newRarity, dominantType, upgradeRandom),
            rarity: newRarity,
            itemType: dominantType,
            power: uint16((totalPower * 120) / 100), // 20% boost
            defense: uint16((totalDefense * 120) / 100),
            magic: uint16((totalMagic * 120) / 100),
            timestamp: uint32(block.timestamp)
        });
       
        // Update player stats
        players[msg.sender].totalLootFound++;
        playerRarityCount[msg.sender][newRarity]++;
       
        // Mint new NFT
        _mint(msg.sender, newTokenId);
        _tokenIdCounter++;
       
        emit LootUpgraded(msg.sender, tokenIds, newTokenId);
       
        // Refund excess payment
        if (msg.value > upgradeFee) {
            payable(msg.sender).transfer(msg.value - upgradeFee);
        }
    }
   
    // Internal helper functions
    function _calculateRarity(uint256 randomSeed, uint256 dungeonLevel)
        private
        pure
        returns (uint8)
    {
        uint256 rarityRoll = randomSeed % 1000;
        uint256 levelBonus = dungeonLevel * 5; // Higher levels = better odds
       
        if (rarityRoll < 10 + levelBonus) return 5; // Legendary
        if (rarityRoll < 50 + levelBonus) return 4; // Epic
        if (rarityRoll < 150 + levelBonus) return 3; // Rare
        if (rarityRoll < 350 + levelBonus) return 2; // Uncommon
        return 1; // Common
    }
   
    function _generateLootName(
        uint8 rarity,
        uint8 itemType,
        uint256 seed
    ) private pure returns (string memory) {
        string[5] memory rarityNames = ["Common", "Uncommon", "Rare", "Epic", "Legendary"];
        string[4] memory typeNames = ["Sword", "Shield", "Ring", "Potion"];
       
        return string(
            abi.encodePacked(
                rarityNames[rarity - 1],
                " ",
                typeNames[itemType - 1],
                " #",
                _toString(seed % 9999)
            )
        );
    }
   
    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
   
    // Admin functions
    function setBaseURI(string memory baseTokenURI) external onlyOwner {
        _baseTokenURI = baseTokenURI;
    }
   
    function setDungeonFee(uint256 newFee) external onlyOwner {
        dungeonBaseFee = newFee;
    }
   
    function pause() external onlyOwner {
        _pause();
    }
   
    function unpause() external onlyOwner {
        _unpause();
    }
   
    function withdrawFees() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
   
    // View functions
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
   
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter;
    }
   
    function getPlayerStats(address player)
        external
        view
        returns (uint256 totalCrawls, uint256 totalLoot, uint256 lastCrawl)
    {
        Player memory p = players[player];
        return (p.totalCrawls, p.totalLootFound, p.lastCrawlTime);
    }
