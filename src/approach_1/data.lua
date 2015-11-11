require 'torch'
require 'nn'
require 'image'
require 'math'
require 'csvigo'
require 'distributions'
require 'gnuplot'
require 'dp'
require 'helpers'


-- parse command line arguments
if not opt then
   print '==> processing options'
   cmd = torch.CmdLine()
   cmd:text()
   cmd:text('Drone Dataset Preprocessing')
   cmd:text()
   cmd:text('Options:')
   cmd:option('-size', 'small', 'how many samples do we load: small | full | extra')
   cmd:option('-visualize', false, 'visualize input data and weights during training')
   cmd:option('-dof', 1, 'degrees of freedom; 1: only x coordinates, 2: x, y; etc.')
   cmd:option('-baseDir', '/home/pold/Documents/draug/', 'Base dir for images and targets')
   cmd:option('-regression', true, 'Base directory for images and targets')
   cmd:option('-standardize', false, 'apply Standardize preprocessing')
   cmd:option('-zca', false, 'apply Zero-Component Analysis whitening')
   cmd:option('-scaleImages', false, 'scale input images to 224 x 224')
   cmd:text()
   opt = cmd:parse(arg or {})
end


-- Settings --

img_folder = opt.baseDir .. "genimgs/"
csv_file = csvigo.load(opt.baseDir .. "targets.csv")

img_width = 224
img_height = 224

-- Amount of synthetic views

----------------------------------------------------------------------
-- training/test size

if opt.size == 'full' then
   print '==> using regular, full training data'
   -- 510 worked perfectly
   trsize = 7000 -- training images
   tesize = 1000 -- test images
   totalSize = 5000
elseif opt.size == 'small' then
   print '==> using reduced training data, for fast experiments'
   trsize = 40
   tesize = 40
   totalSize = 50
elseif opt.size == 'xsmall' then
   print '==> using reduced training data, for fast experiments'
   trsize = 8
   tesize = 8
   totalSize = 15
end


if opt.regression then 
   total_range = 1
else  
   total_range = 350
end

-- Convert csv columns to tensors
local target_x = torch.Tensor(csv_file.x)
local target_y = torch.Tensor(csv_file.y)
local target_z = torch.Tensor(csv_file.z)


trainset = {
   data = torch.Tensor(trsize, 3, img_width, img_height),
   label = torch.FloatTensor(trsize, opt.dof, total_range),
   size = function() return trsize end
}

testset = {
   data = torch.Tensor(tesize, 3, img_width, img_height),
   label = torch.FloatTensor(tesize, opt.dof, total_range),
   size = function() return tesize end
}


-- Sleep for a specified time in seconds
function sleep(n)
  os.execute("sleep " .. tonumber(n))
end


-- Take a 1D-tensor (e.g. with size 300), and split it into classes
-- For example, 1-30: class 1; 31 - 60: class 2; etc.
function to_classes(predictions, classes) 

   if opt.regression then

      width = 35
      pos = predictions[1]
      pos = normalized_to_raw_num(pos, mean_target, std_target)

--      print("Pos is", pos)
   else
      len = predictions:size()
      max, pos = predictions:max(1)
      pos = pos[1]
      width = len[1] / classes -- width of the bins
   end

   class = (math.floor((pos - 1) / width)) + 1

   return math.min(math.max(class, 1), classes)
   

end


function all_classes(labels, num_classes)
  s = labels:size(1)
  tmp_classes = torch.Tensor(s):fill(0)

  for i=1, labels:size(1) do
     if opt.regression then
	class = to_classes(labels[i][1], 10)  
     else
	class = to_classes(labels[i][1], 10)  
     end
    tmp_classes[i] = class
  end

  return tmp_classes
  
end

function all_classes_2d(labels, num_classes)
  s = labels:size(1)
  tmp_classes = torch.Tensor(s):fill(0)

  for i=1, labels:size(1) do
    class = to_classes(labels[i], 10)  
    tmp_classes[i] = class
  end

  return tmp_classes
  
end



function normalized_to_raw(pred, mean_target, stdv_target)
    
    val = pred:clone()
    val = val:cmul(stdv_target)
    val = val:add(mean_target)
    
    return val 
end


function normalized_to_raw_num(pred, mean_target, stdv_target)
    
    val = pred
    val = val * stdv_target
    val = val + mean_target
    
    return val 
end


function raw_to_normalized(pred, mean_target, stdv_target)
    
    val = pred:clone()
    val = val:add(- mean_target)
    val = val:cdiv(stdv_target)
    
    return val 
end



function visualize_data(targets)

   print(targets)
   hist = torch.histc(targets, 10)
   gnuplot.hist(targets, 10, 1, 10)
   print("Histogram", hist)

end

function set_small_nums_to_zero(x)
   val = 0
   if x > 0.01 then
      val = x
   end   
   return val
end      

function makeTargets(y, stdv)

   mean_pos = y / total_range
   
   Y = image.gaussian1D({size=total_range,
			 mean=mean_pos,
			 sigma=.0035,
			 normalize=true})
   Y:apply(set_small_nums_to_zero)

   return Y

end


function load_data_dp(dataPath, validRatio)

   local input = torch.Tensor(totalSize, 3, img_height, img_width)
   local target = torch.IntTensor(totalSize)

   for i = 1, totalSize do

      local img = image.load(dataPath .. "genimgs/" .. (i - 1) .. ".png")
      input[i] = img
      target[i] = target_x[i]
      collectgarbage()
   end

   local nValid = math.floor(totalSize * validRatio)
   local nTrain = totalSize - nValid

   local trainInput = dp.ImageView('bchw', input:narrow(1, 1, nTrain))
   local trainTarget = dp.ClassView('b', target:narrow(1, 1, nTrain))

   local validInput = dp.ImageView('bchw', input:narrow(1, nTrain+1, nValid))
   local validTarget = dp.ClassView('b', target:narrow(1, nTrain+1, nValid))

   -- 3. wrap views into datasets

   local train = dp.DataSet{inputs=trainInput,targets=trainTarget,which_set='train'}
   local valid = dp.DataSet{inputs=validInput,targets=validTarget,which_set='valid'}

   -- 4. wrap datasets into datasource

   local ds = dp.DataSource{train_set=train,valid_set=valid}

   return ds
end

--[[data]]--
ds = load_data_dp(opt.baseDir, 0.2)


--[[preprocessing]]--
local input_preprocess = {}
if opt.standardize then
   table.insert(input_preprocess, dp.Standardize())
end
if opt.zca then
   table.insert(input_preprocess, dp.ZCA())
end
if opt.lecunlcn then
   table.insert(input_preprocess, dp.GCN())
   table.insert(input_preprocess, dp.LeCunLCN{progress=true})
end


trainData = ds:get('train', 'input', 'default') 
testData = ds:get('valid', 'input', 'default')

trainTargets = ds:get('train', 'target', 'default') 
testTargets = ds:get('valid', 'target', 'default')

print(trainTargets)

st = dp.Standardize()
st:apply(trainTargets, true)
st:apply(validTargets, false)

-- Name channels for convenience
channels = {'y','u','v'}

-- Normalize each channel, and store mean/std
-- per channel. These values are important, as they are part of
-- the trainable parameters. At test time, test data will be normalized
-- using these values.
print '==> preprocessing data: normalize each feature (channel) globally'
mean = {}
std = {}
for i,channel in ipairs(channels) do
   -- normalize each channel globally:
   mean[i] = trainData.data[{ {},i,{},{} }]:mean()
   std[i] = trainData.data[{ {},i,{},{} }]:std()
   trainData.data[{ {},i,{},{} }]:add(-mean[i])
   trainData.data[{ {},i,{},{} }]:div(std[i])
end

-- Normalize test data, using the training means/stds
for i,channel in ipairs(channels) do
   -- normalize each channel globally:
   testData.data[{ {},i,{},{} }]:add(-mean[i])
   testData.data[{ {},i,{},{} }]:div(std[i])
end

-- Local normalization
print '==> preprocessing data: normalize all three channels locally'

-- Define the normalization neighborhood:
neighborhood = image.gaussian1D(13)

-- Define our local normalization operator (It is an actual nn module, 
-- which could be inserted into a trainable model):
normalization = nn.SpatialContrastiveNormalization(1, neighborhood, 1):float()

-- Normalize all channels locally:
for c in ipairs(channels) do
   for i = 1,trainData:size() do
      trainData.data[{ i,{c},{},{} }] = normalization:forward(trainData.data[{ i,{c},{},{} }])
   end
   for i = 1,testData:size() do
      testData.data[{ i,{c},{},{} }] = normalization:forward(testData.data[{ i,{c},{},{} }])
   end
end

----------------------------------------------------------------------
print '==> verify statistics'

-- It's always good practice to verify that data is properly
-- normalized.

for i,channel in ipairs(channels) do
   trainMean = trainData.data[{ {},i }]:mean()
   trainStd = trainData.data[{ {},i }]:std()

   testMean = testData.data[{ {},i }]:mean()
   testStd = testData.data[{ {},i }]:std()

   print('training data, '..channel..'-channel, mean: ' .. trainMean)
   print('training data, '..channel..'-channel, standard deviation: ' .. trainStd)

   print('test data, '..channel..'-channel, mean: ' .. testMean)
   print('test data, '..channel..'-channel, standard deviation: ' .. testStd)
end
