-- V003__add_sample_data.sql
-- Insert sample data into the database

-- Sample categories
INSERT INTO categories (name, description) VALUES
('Electronics', 'Electronic devices and gadgets'),
('Clothing', 'Apparel and accessories'),
('Home & Kitchen', 'Products for home and kitchen'),
('Books', 'Books, e-books, and audiobooks'),
('Sports & Outdoors', 'Sports equipment and outdoor gear')
ON CONFLICT (name) DO NOTHING;

-- Sample products
INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Smartphone X',
    'Latest generation smartphone with advanced features',
    699.99,
    100,
    TRUE
FROM categories c
WHERE c.name = 'Electronics'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Laptop Pro',
    '15-inch professional laptop with high performance',
    1299.99,
    50,
    TRUE
FROM categories c
WHERE c.name = 'Electronics'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Wireless Headphones',
    'Noise-cancelling wireless headphones with long battery life',
    199.99,
    200,
    TRUE
FROM categories c
WHERE c.name = 'Electronics'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Cotton T-shirt',
    'Comfortable cotton t-shirt available in multiple colors',
    24.99,
    500,
    TRUE
FROM categories c
WHERE c.name = 'Clothing'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Denim Jeans',
    'Classic denim jeans with straight fit',
    59.99,
    300,
    TRUE
FROM categories c
WHERE c.name = 'Clothing'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Coffee Maker',
    'Programmable coffee maker with 12-cup capacity',
    79.99,
    150,
    TRUE
FROM categories c
WHERE c.name = 'Home & Kitchen'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Non-stick Cookware Set',
    '10-piece non-stick cookware set for versatile cooking',
    149.99,
    100,
    TRUE
FROM categories c
WHERE c.name = 'Home & Kitchen'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Bestselling Novel',
    'Award-winning fiction novel by renowned author',
    14.99,
    1000,
    TRUE
FROM categories c
WHERE c.name = 'Books'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Business Success Guide',
    'Practical guide to business success with real-world examples',
    24.99,
    500,
    TRUE
FROM categories c
WHERE c.name = 'Books'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Yoga Mat',
    'Non-slip yoga mat for home workouts',
    29.99,
    200,
    TRUE
FROM categories c
WHERE c.name = 'Sports & Outdoors'
LIMIT 1;

INSERT INTO products (category_id, name, description, price, stock_quantity, is_active)
SELECT 
    c.id,
    'Hiking Backpack',
    'Waterproof hiking backpack with multiple compartments',
    89.99,
    150,
    TRUE
FROM categories c
WHERE c.name = 'Sports & Outdoors'
LIMIT 1;